/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Parts of this file are derived from SDL 2's Android project template, which
 * has a different license. Please see vendor/SDL/LICENSE.txt for details.
 */
package org.touchhle.android;

import org.libsdl.app.SDLActivity;
import android.os.Bundle;
import android.util.Log;
import android.view.WindowManager;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;

/**
 * A wrapper class over SDLActivity
 */

public class MainActivity extends SDLActivity {
    private static final String TAG = "touchHLE";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        if (mLayout != null) {
            mLayout.setKeepScreenOn(true);
        }
        if (mSurface != null) {
            mSurface.setKeepScreenOn(true);
        }
    }

    @Override
    protected String[] getLibraries() {
        return new String[]{
            "SDL2",
            "touchHLE"
        };
    }

    @Override
    protected String[] getArguments() {
        if (BuildConfig.IS_STANDALONE) {
            File targetDir = getExternalFilesDir(null);
            if (targetDir == null) {
                targetDir = getFilesDir();
            }
            File appsDir = new File(targetDir, "touchHLE_apps");
            if (!appsDir.exists()) {
                appsDir.mkdirs();
            }
            File gameFile = new File(appsDir, BuildConfig.STANDALONE_GAME_NAME);
            if (!gameFile.exists()) {
                Log.i(TAG, "Extracting bundled game: " + BuildConfig.STANDALONE_GAME_NAME);
                try (InputStream in = getAssets().open("bundled_game.ipa");
                     OutputStream out = new FileOutputStream(gameFile)) {
                    byte[] buffer = new byte[65536];
                    int read;
                    while ((read = in.read(buffer)) != -1) {
                        out.write(buffer, 0, read);
                    }
                    out.flush();
                    Log.i(TAG, "Bundled game extracted successfully");
                } catch (Exception e) {
                    Log.e(TAG, "Failed to extract bundled game", e);
                }
            }
            return new String[]{
                gameFile.getAbsolutePath()
            };
        }
        return new String[0];
    }
}
