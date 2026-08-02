package com.github.catvod;

import android.content.Context;

import java.lang.ref.WeakReference;

/**
 * App CL 宿主 Init（迅雷 AAR + 站点父优先都会命中本类）。
 * 与 TV catvod Init ABI 一致；须在任何 Path/Thunder 调用前 {@link #set(Context)}。
 */
public class Init {

    private WeakReference<Context> context;

    private static Init get() {
        return Loader.INSTANCE;
    }

    public static void set(Context context) {
        if (context == null) return;
        Context app = context.getApplicationContext();
        get().context = new WeakReference<>(app != null ? app : context);
    }

    public static Context context() {
        WeakReference<Context> ref = get().context;
        return ref == null ? null : ref.get();
    }

    private static class Loader {
        static volatile Init INSTANCE = new Init();
    }
}
