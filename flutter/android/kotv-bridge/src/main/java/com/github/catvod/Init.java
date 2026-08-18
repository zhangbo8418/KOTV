package com.github.catvod;

import android.app.Activity;
import android.content.Context;

import com.bobo.kotv.host.UiContext;

import java.lang.ref.WeakReference;

/**
 * App CL 宿主 Init（迅雷 AAR + 站点父优先都会命中本类）。
 * 与 TV catvod Init ABI 一致；须在任何 Path/Thunder 调用前 {@link #set(Context)}。
 * {@link #uiContext()} 供宿主侧 AlertDialog 等优先拿当前 Activity（对齐 TV {@code App.activity()}）。
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
        if (app instanceof android.app.Application) {
            UiContext.setApplication((android.app.Application) app);
        }
        if (context instanceof Activity) {
            UiContext.setActivity((Activity) context);
        }
    }

    public static Context context() {
        WeakReference<Context> ref = get().context;
        return ref == null ? null : ref.get();
    }

    /** 当前前台 Activity；无则 null（对齐 TV App.activity()）。 */
    public static Activity activity() {
        return UiContext.activity();
    }

    /** 弹窗/Toast 优先 Activity，否则 Application。 */
    public static Context uiContext() {
        Context ui = UiContext.forUi();
        return ui != null ? ui : context();
    }

    private static class Loader {
        static volatile Init INSTANCE = new Init();
    }
}
