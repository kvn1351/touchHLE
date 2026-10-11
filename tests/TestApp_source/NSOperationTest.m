/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

#include <pthread.h>
#include <semaphore.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "system_headers.h"

typedef struct {
  pthread_mutex_t mutex;
  int mutex_initialized;
  sem_t started[3];
  int started_count;
  sem_t finished[3];
  int finished_count;
  sem_t release[3];
  int release_count;
  sem_t wait_entered;
  int wait_entered_initialized;
  sem_t wait_returned;
  int wait_returned_initialized;
  pthread_t enqueue_thread;
  pthread_t worker_thread;
  int worker_thread_set;
  int active;
  int max_active;
  int order[3];
  int order_count;
  int executed[3];
  int executing_seen[3];
  int finished_seen[3];
} operation_test_context;

static void operation_test_context_destroy(operation_test_context *context) {
  int i;
  for (i = 0; i < context->started_count; i++)
    sem_destroy(&context->started[i]);
  for (i = 0; i < context->finished_count; i++)
    sem_destroy(&context->finished[i]);
  for (i = 0; i < context->release_count; i++)
    sem_destroy(&context->release[i]);
  if (context->wait_entered_initialized)
    sem_destroy(&context->wait_entered);
  if (context->wait_returned_initialized)
    sem_destroy(&context->wait_returned);
  if (context->mutex_initialized)
    pthread_mutex_destroy(&context->mutex);
}

static int operation_test_context_init(operation_test_context *context) {
  int i;
  memset(context, 0, sizeof(*context));
  if (pthread_mutex_init(&context->mutex, NULL) != 0)
    return 0;
  context->mutex_initialized = 1;
  for (i = 0; i < 3; i++) {
    if (sem_init(&context->started[i], 0, 0) != 0)
      goto failed;
    context->started_count++;
    if (sem_init(&context->finished[i], 0, 0) != 0)
      goto failed;
    context->finished_count++;
    if (sem_init(&context->release[i], 0, 0) != 0)
      goto failed;
    context->release_count++;
  }
  if (sem_init(&context->wait_entered, 0, 0) != 0)
    goto failed;
  context->wait_entered_initialized = 1;
  if (sem_init(&context->wait_returned, 0, 0) != 0)
    goto failed;
  context->wait_returned_initialized = 1;
  return 1;

failed:
  operation_test_context_destroy(context);
  return 0;
}

// This is a bounded wait only to turn a scheduler failure into a test failure;
// no elapsed time is part of the behavior being tested.
static int operation_test_wait(sem_t *semaphore) {
  int i;
  for (i = 0; i < 10000; i++) {
    if (sem_trywait(semaphore) == 0)
      return 1;
    usleep(1000);
  }
  return 0;
}

@interface OperationRegressionOperation : NSOperation {
  operation_test_context *context;
  int marker;
  int blocks;
}
- (instancetype)initWithContext:(operation_test_context *)context
                          marker:(int)marker
                          blocks:(int)blocks;
@end

@implementation OperationRegressionOperation

- (instancetype)initWithContext:(operation_test_context *)new_context
                          marker:(int)new_marker
                          blocks:(int)new_blocks {
  self = [super init];
  if (self != nil) {
    context = new_context;
    marker = new_marker;
    blocks = new_blocks;
  }
  return self;
}

- (void)main {
  pthread_mutex_lock(&context->mutex);
  context->active++;
  if (context->active > context->max_active)
    context->max_active = context->active;
  if (context->order_count < 3)
    context->order[context->order_count++] = marker;
  context->executed[marker]++;
  context->executing_seen[marker] = [self isExecuting] ? 1 : 0;
  context->finished_seen[marker] = [self isFinished] ? 1 : 0;
  if (!context->worker_thread_set) {
    context->worker_thread = pthread_self();
    context->worker_thread_set = 1;
  }
  pthread_mutex_unlock(&context->mutex);

  sem_post(&context->started[marker]);
  if (blocks)
    sem_wait(&context->release[marker]);

  pthread_mutex_lock(&context->mutex);
  context->active--;
  pthread_mutex_unlock(&context->mutex);
  sem_post(&context->finished[marker]);
}

@end

typedef struct {
  NSOperationQueue *queue;
  sem_t *entered;
  sem_t *returned;
} operation_waiter_arguments;

static void *operation_test_waiter(void *argument) {
  operation_waiter_arguments *arguments = argument;
  sem_post(arguments->entered);
  [arguments->queue waitUntilAllOperationsAreFinished];
  sem_post(arguments->returned);
  [arguments->queue release];
  return NULL;
}

int test_NSOperationQueue_serial_execution(void) {
  operation_test_context *context = calloc(1, sizeof(*context));
  NSOperationQueue *queue = nil;
  OperationRegressionOperation *first = nil;
  OperationRegressionOperation *second = nil;
  int operations_added = 0;
  int first_started = 0;
  int second_added = 0;
  int first_released = 0;
  int first_finished = 0;
  int second_started = 0;
  int second_finished = 0;
  int result = 0;
  int safe_to_destroy = 1;

  if (context == NULL || !operation_test_context_init(context)) {
    free(context);
    return -1;
  }
  context->enqueue_thread = pthread_self();
  queue = [[NSOperationQueue alloc] init];
  first = [[OperationRegressionOperation alloc] initWithContext:context
                                                         marker:1
                                                         blocks:1];
  second = [[OperationRegressionOperation alloc] initWithContext:context
                                                          marker:2
                                                          blocks:0];
  if (queue == nil || first == nil || second == nil) {
    result = -2;
    goto cleanup;
  }
  [queue setMaxConcurrentOperationCount:1];
  if ([queue maxConcurrentOperationCount] != 1 || ![first isReady] ||
      [first isExecuting] || [first isFinished] || [first isCancelled] ||
      [first isConcurrent]) {
    result = -3;
    goto cleanup;
  }

  [queue addOperation:first];
  operations_added = 1;
  if (!operation_test_wait(&context->started[1])) {
    result = -4;
    safe_to_destroy = 0;
    goto cleanup;
  }
  first_started = 1;
  if (!context->worker_thread_set ||
      pthread_equal(context->worker_thread, context->enqueue_thread)) {
    result = -5;
    goto cleanup;
  }
  if (![first isExecuting] || [first isFinished] ||
      !context->executing_seen[1] || context->finished_seen[1]) {
    result = -6;
    goto cleanup;
  }

  [queue addOperation:second];
  second_added = 1;
  if (sem_trywait(&context->started[2]) == 0) {
    second_started = 1;
    result = -7;
    goto cleanup;
  }

  sem_post(&context->release[1]);
  first_released = 1;
  if (!operation_test_wait(&context->finished[1])) {
    result = -8;
    safe_to_destroy = 0;
    goto cleanup;
  }
  first_finished = 1;
  if (!operation_test_wait(&context->started[2])) {
    result = -9;
    safe_to_destroy = 0;
    goto cleanup;
  }
  second_started = 1;
  if (!operation_test_wait(&context->finished[2])) {
    result = -10;
    safe_to_destroy = 0;
    goto cleanup;
  }
  second_finished = 1;
  [queue waitUntilAllOperationsAreFinished];
  if (![first isFinished] || [first isExecuting] || ![second isFinished] ||
      [second isExecuting] || context->order_count != 2 ||
      context->order[0] != 1 || context->order[1] != 2 ||
      context->max_active != 1 || context->active != 0 ||
      [queue operationCount] != 0) {
    result = -11;
  }

cleanup:
  if (operations_added && !first_released) {
    sem_post(&context->release[1]);
    first_released = 1;
  }
  if (operations_added && !first_started) {
    if (operation_test_wait(&context->started[1]))
      first_started = 1;
    else
      safe_to_destroy = 0;
  }
  if (first_started && !first_finished) {
    if (operation_test_wait(&context->finished[1]))
      first_finished = 1;
    else
      safe_to_destroy = 0;
  }
  if (second_added && !second_started) {
    if (operation_test_wait(&context->started[2]))
      second_started = 1;
    else
      safe_to_destroy = 0;
  }
  if (second_started && !second_finished) {
    if (operation_test_wait(&context->finished[2]))
      second_finished = 1;
    else
      safe_to_destroy = 0;
  }
  if (first != nil)
    [first release];
  if (second != nil)
    [second release];
  if (queue != nil)
    [queue release];
  if (safe_to_destroy) {
    operation_test_context_destroy(context);
    free(context);
  }
  return result;
}

int test_NSOperationQueue_parallel_execution(void) {
  operation_test_context *context = calloc(1, sizeof(*context));
  NSOperationQueue *queue = nil;
  OperationRegressionOperation *first = nil;
  OperationRegressionOperation *second = nil;
  operation_waiter_arguments *waiter_arguments = NULL;
  pthread_t waiter_thread;
  int waiter_created = 0;
  int waiter_finished = 0;
  int operations_added = 0;
  int first_started = 0;
  int second_started = 0;
  int first_released = 0;
  int second_released = 0;
  int first_finished = 0;
  int second_finished = 0;
  int result = 0;
  int safe_to_destroy = 1;

  if (context == NULL || !operation_test_context_init(context)) {
    free(context);
    return -1;
  }
  context->enqueue_thread = pthread_self();
  queue = [[NSOperationQueue alloc] init];
  first = [[OperationRegressionOperation alloc] initWithContext:context
                                                         marker:1
                                                         blocks:1];
  second = [[OperationRegressionOperation alloc] initWithContext:context
                                                          marker:2
                                                          blocks:1];
  if (queue == nil || first == nil || second == nil) {
    result = -2;
    goto parallel_cleanup;
  }
  [queue setMaxConcurrentOperationCount:2];
  if ([queue maxConcurrentOperationCount] != 2) {
    result = -3;
    goto parallel_cleanup;
  }
  [queue addOperation:first];
  [queue addOperation:second];
  operations_added = 1;
  if (!operation_test_wait(&context->started[1])) {
    result = -4;
    safe_to_destroy = 0;
    goto parallel_cleanup;
  }
  first_started = 1;
  if (!operation_test_wait(&context->started[2])) {
    result = -5;
    safe_to_destroy = 0;
    goto parallel_cleanup;
  }
  second_started = 1;
  if (context->executed[1] != 1 || context->executed[2] != 1 ||
      context->active != 2 || context->max_active != 2 || [first isFinished] ||
      [second isFinished]) {
    result = -6;
    goto parallel_cleanup;
  }

  waiter_arguments = calloc(1, sizeof(*waiter_arguments));
  if (waiter_arguments == NULL) {
    result = -7;
    goto parallel_cleanup;
  }
  waiter_arguments->queue = [queue retain];
  waiter_arguments->entered = &context->wait_entered;
  waiter_arguments->returned = &context->wait_returned;
  if (pthread_create(&waiter_thread, NULL, operation_test_waiter,
                     waiter_arguments) != 0) {
    [waiter_arguments->queue release];
    free(waiter_arguments);
    waiter_arguments = NULL;
    result = -8;
    goto parallel_cleanup;
  }
  waiter_created = 1;
  if (!operation_test_wait(&context->wait_entered)) {
    result = -9;
    safe_to_destroy = 0;
    goto parallel_cleanup;
  }

  sem_post(&context->release[1]);
  first_released = 1;
  if (!operation_test_wait(&context->finished[1])) {
    result = -10;
    safe_to_destroy = 0;
    goto parallel_cleanup;
  }
  first_finished = 1;
  if (sem_trywait(&context->wait_returned) == 0) {
    waiter_finished = 1;
    result = -11;
    goto parallel_cleanup;
  }

  sem_post(&context->release[2]);
  second_released = 1;
  if (!operation_test_wait(&context->finished[2])) {
    result = -12;
    safe_to_destroy = 0;
    goto parallel_cleanup;
  }
  second_finished = 1;
  if (!operation_test_wait(&context->wait_returned)) {
    result = -13;
    safe_to_destroy = 0;
    goto parallel_cleanup;
  }
  waiter_finished = 1;
  if (![first isFinished] || ![second isFinished] ||
      context->executed[1] != 1 || context->executed[2] != 1 ||
      context->active != 0 || context->max_active != 2 ||
      [queue operationCount] != 0) {
    result = -14;
  }

parallel_cleanup:
  if (operations_added && !first_released) {
    sem_post(&context->release[1]);
    first_released = 1;
  }
  if (operations_added && !second_released) {
    sem_post(&context->release[2]);
    second_released = 1;
  }
  if (operations_added && !first_started) {
    if (operation_test_wait(&context->started[1]))
      first_started = 1;
    else
      safe_to_destroy = 0;
  }
  if (operations_added && !second_started) {
    if (operation_test_wait(&context->started[2]))
      second_started = 1;
    else
      safe_to_destroy = 0;
  }
  if (first_started && !first_finished) {
    if (operation_test_wait(&context->finished[1]))
      first_finished = 1;
    else
      safe_to_destroy = 0;
  }
  if (second_started && !second_finished) {
    if (operation_test_wait(&context->finished[2]))
      second_finished = 1;
    else
      safe_to_destroy = 0;
  }
  if (waiter_created && !waiter_finished) {
    if (operation_test_wait(&context->wait_returned)) {
      waiter_finished = 1;
      pthread_join(waiter_thread, NULL);
      free(waiter_arguments);
      waiter_arguments = NULL;
    } else {
      safe_to_destroy = 0;
    }
  } else if (waiter_created) {
    pthread_join(waiter_thread, NULL);
    free(waiter_arguments);
    waiter_arguments = NULL;
  }
  if (first != nil)
    [first release];
  if (second != nil)
    [second release];
  if (queue != nil)
    [queue release];
  if (safe_to_destroy) {
    operation_test_context_destroy(context);
    free(context);
  }
  return result;
}

int test_NSOperationQueue_cancellation_and_lifetime(void) {
  operation_test_context *context = calloc(1, sizeof(*context));
  NSOperationQueue *queue = nil;
  OperationRegressionOperation *cancelled = nil;
  OperationRegressionOperation *survivor = nil;
  OperationRegressionOperation *dropped = nil;
  int survivor_started = 0;
  int survivor_finished = 0;
  int result = 0;
  int operations_added = 0;
  int safe_to_destroy = 1;

  if (context == NULL || !operation_test_context_init(context)) {
    free(context);
    return -1;
  }
  context->enqueue_thread = pthread_self();
  queue = [[NSOperationQueue alloc] init];
  cancelled = [[OperationRegressionOperation alloc] initWithContext:context
                                                              marker:1
                                                              blocks:0];
  survivor = [[OperationRegressionOperation alloc] initWithContext:context
                                                             marker:2
                                                             blocks:0];
  if (queue == nil || cancelled == nil || survivor == nil) {
    result = -2;
    goto cancellation_cleanup;
  }
  [queue setMaxConcurrentOperationCount:0];
  [cancelled cancel];
  if (![cancelled isCancelled] || ![cancelled isReady] ||
      [cancelled isFinished]) {
    result = -3;
    goto cancellation_cleanup;
  }
  [queue addOperation:cancelled];
  [queue addOperation:survivor];
  operations_added = 1;
  if ([queue operationCount] != 2) {
    result = -4;
    goto cancellation_cleanup;
  }
  [queue setMaxConcurrentOperationCount:1];
  if (!operation_test_wait(&context->started[2])) {
    result = -5;
    safe_to_destroy = 0;
    goto cancellation_cleanup;
  }
  survivor_started = 1;
  if (!operation_test_wait(&context->finished[2])) {
    result = -6;
    safe_to_destroy = 0;
    goto cancellation_cleanup;
  }
  survivor_finished = 1;
  [queue waitUntilAllOperationsAreFinished];
  if (![cancelled isFinished] || context->executed[1] != 0 ||
      ![survivor isFinished] || [queue operationCount] != 0)
    result = -7;

cancellation_cleanup:
  if (queue != nil && operations_added && !survivor_started) {
    [queue setMaxConcurrentOperationCount:1];
    if (operation_test_wait(&context->started[2]))
      survivor_started = 1;
    else
      safe_to_destroy = 0;
  }
  if (survivor_started && !survivor_finished) {
    if (operation_test_wait(&context->finished[2]))
      survivor_finished = 1;
    else
      safe_to_destroy = 0;
  }
  if (cancelled != nil)
    [cancelled release];
  if (survivor != nil)
    [survivor release];
  if (queue != nil)
    [queue release];
  if (safe_to_destroy) {
    operation_test_context_destroy(context);
    free(context);
  }
  if (result != 0 || !safe_to_destroy)
    return result;

  // Drop both caller-owned references while the operation is blocked. The
  // completion signal proves the queue retained and ran the work itself.
  context = calloc(1, sizeof(*context));
  if (context == NULL || !operation_test_context_init(context)) {
    free(context);
    return -8;
  }
  context->enqueue_thread = pthread_self();
  queue = [[NSOperationQueue alloc] init];
  dropped = [[OperationRegressionOperation alloc] initWithContext:context
                                                            marker:1
                                                            blocks:1];
  if (queue == nil || dropped == nil) {
    if (dropped != nil)
      [dropped release];
    if (queue != nil)
      [queue release];
    operation_test_context_destroy(context);
    free(context);
    return -9;
  }
  [queue setMaxConcurrentOperationCount:1];
  [queue addOperation:dropped];
  if (!operation_test_wait(&context->started[1])) {
    sem_post(&context->release[1]);
    if (operation_test_wait(&context->finished[1])) {
      [dropped release];
      [queue release];
      operation_test_context_destroy(context);
      free(context);
    } else {
      [dropped release];
      [queue release];
    }
    return -10;
  }
  [dropped release];
  [queue release];
  sem_post(&context->release[1]);
  if (!operation_test_wait(&context->finished[1])) {
    // Keep the heap context alive for a late worker rather than freeing
    // storage that the operation still references.
    return -11;
  }
  if (!context->executed[1] || !context->worker_thread_set ||
      pthread_equal(context->worker_thread, context->enqueue_thread)) {
    operation_test_context_destroy(context);
    free(context);
    return -12;
  }
  operation_test_context_destroy(context);
  free(context);
  return 0;
}
