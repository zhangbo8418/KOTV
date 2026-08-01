package com.github.catvod;

import android.content.Context;

import java.lang.ref.WeakReference;

/** Minimal shim for thunder-release.aar (same API surface as TV catvod Init). */
public class Init {

    private WeakReference<Context> context;

    private static Init get() {
        return Loader.INSTANCE;
    }

    public static void set(Context context) {
        get().context = new WeakReference<>(context.getApplicationContext());
    }

    public static Context context() {
        return get().context.get();
    }

    private static class Loader {
        static volatile Init INSTANCE = new Init();
    }
}
