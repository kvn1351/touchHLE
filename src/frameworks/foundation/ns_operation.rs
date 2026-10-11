/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
//! Basic, non-concurrent `NSOperation` and `NSOperationQueue` support.
//!
//! The queue workers are guest `NSThread`s.  Keeping all scheduling state in
//! host objects means that the queue and operations remain valid even when the
//! guest drops its last reference while a worker is still using them.

use super::{NSInteger, NSUInteger};
use crate::frameworks::foundation::ns_thread::detach_new_thread_inner;
use crate::libc::pthread::cond::{
    pthread_cond_broadcast, pthread_cond_destroy, pthread_cond_init, pthread_cond_t,
    pthread_cond_wait,
};
use crate::libc::pthread::mutex::{
    pthread_mutex_destroy, pthread_mutex_init, pthread_mutex_lock, pthread_mutex_t,
    pthread_mutex_unlock,
};
use crate::mem::{guest_size_of, ConstPtr, MutPtr};
use crate::objc::{
    id, msg, msg_class, nil, objc_classes, release, retain, ClassExports, HostObject, NSZonePtr,
};
use crate::Environment;
use std::collections::VecDeque;

const DEFAULT_WORKER_COUNT: usize = 4;

#[derive(Clone, Copy, PartialEq, Eq)]
enum OperationState {
    Ready,
    Executing,
    Finished,
}

struct NSOperationHostObject {
    mutex: MutPtr<pthread_mutex_t>,
    cond: MutPtr<pthread_cond_t>,
    state: OperationState,
    cancelled: bool,
    queued: bool,
}
impl HostObject for NSOperationHostObject {}

struct NSOperationQueueHostObject {
    mutex: MutPtr<pthread_mutex_t>,
    cond: MutPtr<pthread_cond_t>,
    /// Strong references to operations that have not yet been started.
    pending_operations: VecDeque<id>,
    running: usize,
    worker_count: usize,
    max_concurrent_operation_count: NSInteger,
}
impl HostObject for NSOperationQueueHostObject {}

pub const CLASSES: ClassExports = objc_classes! {

(env, this, _cmd);

@implementation NSOperation: NSObject

+ (id)allocWithZone:(NSZonePtr)_zone {
    let (mutex, cond) = alloc_sync_objects(env);
    let host_object = Box::new(NSOperationHostObject {
        mutex,
        cond,
        state: OperationState::Ready,
        cancelled: false,
        queued: false,
    });
    env.objc.alloc_object(this, host_object, &mut env.mem)
}

- (())start {
    // This module intentionally supports only synchronous, non-concurrent
    // operations.  A subclass advertising concurrency has no safe execution
    // model here, so fail instead of silently reporting completion.
    let concurrent: bool = msg![env; this isConcurrent];
    assert!(!concurrent, "asynchronous NSOperation subclasses are unsupported");

    let (mutex, cond) = {
        let host = env.objc.borrow::<NSOperationHostObject>(this);
        (host.mutex, host.cond)
    };
    pthread_mutex_lock(env, mutex);
    let (should_run, cancelled_before_start) = {
        let host = env.objc.borrow_mut::<NSOperationHostObject>(this);
        match host.state {
            OperationState::Finished | OperationState::Executing => (false, false),
            OperationState::Ready if host.cancelled => {
                host.state = OperationState::Finished;
                (false, true)
            }
            OperationState::Ready => {
                host.state = OperationState::Executing;
                (true, false)
            }
        }
    };
    if cancelled_before_start {
        pthread_cond_broadcast(env, cond);
    }
    pthread_mutex_unlock(env, mutex);

    if !should_run {
        return;
    }

    // Do not keep a host-object borrow across this guest call: `main` can
    // yield, and subclasses are allowed to send arbitrary messages.
    () = msg![env; this main];

    pthread_mutex_lock(env, mutex);
    {
        let host = env.objc.borrow_mut::<NSOperationHostObject>(this);
        host.state = OperationState::Finished;
    }
    pthread_cond_broadcast(env, cond);
    pthread_mutex_unlock(env, mutex);
}

- (())main {
    // NSObject-style default implementation.  Subclasses do the useful work.
}

- (bool)isExecuting {
    // Host-only reads cannot yield to another emulated thread.
    env.objc.borrow::<NSOperationHostObject>(this).state == OperationState::Executing
}

- (bool)isFinished {
    env.objc.borrow::<NSOperationHostObject>(this).state == OperationState::Finished
}

- (bool)isCancelled {
    env.objc.borrow::<NSOperationHostObject>(this).cancelled
}

- (bool)isReady {
    env.objc.borrow::<NSOperationHostObject>(this).state == OperationState::Ready
}

- (bool)isConcurrent {
    false
}

- (())cancel {
    let mutex = env.objc.borrow::<NSOperationHostObject>(this).mutex;
    pthread_mutex_lock(env, mutex);
    {
        let host = env.objc.borrow_mut::<NSOperationHostObject>(this);
        host.cancelled = true;
    }
    pthread_mutex_unlock(env, mutex);
}

- (())waitUntilFinished {
    let (mutex, cond) = {
        let host = env.objc.borrow::<NSOperationHostObject>(this);
        (host.mutex, host.cond)
    };
    pthread_mutex_lock(env, mutex);
    while env.objc.borrow::<NSOperationHostObject>(this).state != OperationState::Finished {
        pthread_cond_wait(env, cond, mutex);
    }
    pthread_mutex_unlock(env, mutex);
}

- (())dealloc {
    let (mutex, cond) = {
        let host = env.objc.borrow::<NSOperationHostObject>(this);
        (host.mutex, host.cond)
    };
    pthread_cond_destroy(env, cond);
    pthread_mutex_destroy(env, mutex);
    env.mem.free(cond.cast());
    env.mem.free(mutex.cast());
    env.objc.dealloc_object(this, &mut env.mem)
}

@end

@implementation NSOperationQueue: NSObject

+ (id)allocWithZone:(NSZonePtr)_zone {
    let (mutex, cond) = alloc_sync_objects(env);
    let host_object = Box::new(NSOperationQueueHostObject {
        mutex,
        cond,
        pending_operations: VecDeque::new(),
        running: 0,
        worker_count: 0,
        max_concurrent_operation_count: -1,
    });
    env.objc.alloc_object(this, host_object, &mut env.mem)
}

- (())addOperation:(id)operation {
    assert!(operation != nil, "cannot enqueue nil NSOperation");
    claim_operation_for_queue(env, operation);
    // Retain before taking the queue lock: retain is a guest message and may
    // re-enter arbitrary Objective-C code.
    retain(env, operation);
    let (mutex, cond) = {
        let host = env.objc.borrow::<NSOperationQueueHostObject>(this);
        (host.mutex, host.cond)
    };
    pthread_mutex_lock(env, mutex);
    env.objc
        .borrow_mut::<NSOperationQueueHostObject>(this)
        .pending_operations
        .push_back(operation);
    pthread_cond_broadcast(env, cond);
    pthread_mutex_unlock(env, mutex);
    ensure_workers_started(env, this);
}

- (NSInteger)maxConcurrentOperationCount {
    env.objc
        .borrow::<NSOperationQueueHostObject>(this)
        .max_concurrent_operation_count
}

- (())setMaxConcurrentOperationCount:(NSInteger)count {
    assert!(count >= -1, "invalid NSOperationQueue concurrency limit");
    let (mutex, cond) = {
        let host = env.objc.borrow::<NSOperationQueueHostObject>(this);
        (host.mutex, host.cond)
    };
    pthread_mutex_lock(env, mutex);
    {
        let host = env.objc.borrow_mut::<NSOperationQueueHostObject>(this);
        host.max_concurrent_operation_count = count;
    }
    pthread_cond_broadcast(env, cond);
    pthread_mutex_unlock(env, mutex);
    ensure_workers_started(env, this);
}

- (NSUInteger)operationCount {
    let host = env.objc.borrow::<NSOperationQueueHostObject>(this);
    (host.pending_operations.len() + host.running) as NSUInteger
}

- (())waitUntilAllOperationsAreFinished {
    let (mutex, cond) = {
        let host = env.objc.borrow::<NSOperationQueueHostObject>(this);
        (host.mutex, host.cond)
    };
    pthread_mutex_lock(env, mutex);
    while {
        let host = env.objc.borrow::<NSOperationQueueHostObject>(this);
        !host.pending_operations.is_empty() || host.running != 0
    } {
        pthread_cond_wait(env, cond, mutex);
    }
    pthread_mutex_unlock(env, mutex);
}

- (())_touchHLE_runOperationQueueWorker:(id)_object {
    loop {
        let (mutex, cond) = {
            let host = env.objc.borrow::<NSOperationQueueHostObject>(this);
            (host.mutex, host.cond)
        };
        pthread_mutex_lock(env, mutex);

        let operation = loop {
            let (max_count, running, pending) = {
                let host = env.objc.borrow::<NSOperationQueueHostObject>(this);
                (
                    host.max_concurrent_operation_count,
                    host.running,
                    host.pending_operations.front().copied(),
                )
            };
            let limit = worker_limit(max_count);
            if limit == 0 || pending.is_none() {
                {
                    let host = env.objc.borrow_mut::<NSOperationQueueHostObject>(this);
                    host.worker_count -= 1;
                }
                pthread_cond_broadcast(env, cond);
                pthread_mutex_unlock(env, mutex);
                return;
            }
            if running >= limit {
                pthread_cond_wait(env, cond, mutex);
                continue;
            }
            let operation = {
                let host = env.objc.borrow_mut::<NSOperationQueueHostObject>(this);
                let operation = host.pending_operations.pop_front().unwrap();
                host.running += 1;
                operation
            };
            break operation;
        };
        pthread_mutex_unlock(env, mutex);

        // Generic operations get their own pool in addition to any pool a
        // subclass may create.
        let pool: id = msg_class![env; NSAutoreleasePool new];
        () = msg![env; operation start];
        release(env, pool);

        pthread_mutex_lock(env, mutex);
        {
            let host = env.objc.borrow_mut::<NSOperationQueueHostObject>(this);
            host.running -= 1;
        }
        pthread_cond_broadcast(env, cond);
        pthread_mutex_unlock(env, mutex);
        // Queue ownership is released only after the operation has finished.
        release(env, operation);
    }
}

- (())dealloc {
    let (mutex, cond, operations) = {
        let host = env.objc.borrow_mut::<NSOperationQueueHostObject>(this);
        (
            host.mutex,
            host.cond,
            std::mem::take(&mut host.pending_operations),
        )
    };
    for operation in operations {
        release(env, operation);
    }
    pthread_cond_destroy(env, cond);
    pthread_mutex_destroy(env, mutex);
    env.mem.free(cond.cast());
    env.mem.free(mutex.cast());
    env.objc.dealloc_object(this, &mut env.mem)
}

@end

};

fn claim_operation_for_queue(env: &mut Environment, operation: id) {
    let mutex = env.objc.borrow::<NSOperationHostObject>(operation).mutex;
    pthread_mutex_lock(env, mutex);
    let accepted = {
        let host = env.objc.borrow_mut::<NSOperationHostObject>(operation);
        if host.queued || host.state != OperationState::Ready {
            false
        } else {
            host.queued = true;
            true
        }
    };
    pthread_mutex_unlock(env, mutex);
    assert!(accepted, "NSOperation cannot be enqueued more than once");
}

fn alloc_sync_objects(env: &mut Environment) -> (MutPtr<pthread_mutex_t>, MutPtr<pthread_cond_t>) {
    let mutex = env.mem.alloc(guest_size_of::<pthread_mutex_t>()).cast();
    let cond = env.mem.alloc(guest_size_of::<pthread_cond_t>()).cast();
    assert_eq!(pthread_mutex_init(env, mutex, ConstPtr::null()), 0);
    assert_eq!(pthread_cond_init(env, cond, ConstPtr::null()), 0);
    (mutex, cond)
}

fn worker_limit(max_count: NSInteger) -> usize {
    if max_count < 0 {
        DEFAULT_WORKER_COUNT
    } else {
        max_count as usize
    }
}

/// Start enough guest NSThreads to consume currently queued operations.  The
/// worker count is reserved before creating threads so reentrant callbacks do
/// not start duplicate workers.
fn ensure_workers_started(env: &mut Environment, queue: id) {
    let mutex = env.objc.borrow::<NSOperationQueueHostObject>(queue).mutex;
    pthread_mutex_lock(env, mutex);
    let start_count = {
        let host = env.objc.borrow_mut::<NSOperationQueueHostObject>(queue);
        let to_start = worker_limit(host.max_concurrent_operation_count);
        let total = host.pending_operations.len() + host.running;
        let desired = to_start.min(total);
        let start_count = desired.saturating_sub(host.worker_count);
        host.worker_count += start_count;
        start_count
    };
    pthread_mutex_unlock(env, mutex);

    if start_count == 0 {
        return;
    }
    let selector = env
        .objc
        .lookup_selector("_touchHLE_runOperationQueueWorker:")
        .expect("NSOperationQueue worker selector is registered");
    for _ in 0..start_count {
        detach_new_thread_inner(env, selector, queue, nil, false);
    }
}
