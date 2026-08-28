package com.github.catvod;

import android.app.Activity;
import android.app.Application;
import android.content.Context;

import com.bobo.kotv.host.UiContext;
import com.bobo.kotv.host.DialogRelay;
import com.github.catvod.utils.Util;

/**
 * App CL 宿主 Init（迅雷 AAR + 站点父优先都会命中本类）。
 * 与 TV catvod Init ABI 一致；须在任何 Path/Thunder 调用前 {@link #set(Context)}。
 * {@link #uiContext()} 供宿主侧 AlertDialog 等优先拿当前 Activity（对齐 TV {@code App.activity()}）。
 *
 * <p>Application 用强引用：WeakReference 在 attachBaseContext 阶段若只拿到短暂 Context，
 * 会被回收，站点 jar 随后 {@code Init.context().getPackageName()} NPE。
 */
public class Init {

    private static volatile Context appContext;

    private static Init get() {
        return Loader.INSTANCE;
    }

    public static void set(Context context) {
        if (context == null) return;
        Context app = context.getApplicationContext();
        if (app == null) app = context;
        if (app instanceof Application) {
            appContext = app;
            UiContext.setApplication((Application) app);
        } else if (appContext == null) {
            appContext = app;
        }
        if (context instanceof Activity) {
            UiContext.setActivity((Activity) context);
        }
    }

    public static Context context() {
        Context c = appContext;
        if (c != null) return c;
        Application app = UiContext.application();
        if (app != null) {
            appContext = app;
            return app;
        }
        return null;
    }

    /** 当前前台 Activity。默认 null，对齐 TV catvod Init（无 activity 方法）；仅 remoteUi 时暴露，避免 jar Init 弹 WebView 配置页。 */
    public static Activity activity() {
        if (!Util.hasRemoteUi()) {
            return null;
        }
        return UiContext.activity();
    }

    /** 弹窗/Toast 优先 Activity，否则 Application。远端客户端时包一层 WindowManager 中继。 */
    public static Context uiContext() {
        if (!Util.hasRemoteUi()) {
            return context();
        }
        Context ui = UiContext.forUi();
        Context raw = ui != null ? ui : context();
        return DialogRelay.maybeWrap(raw);
    }

    private static class Loader {
        static volatile Init INSTANCE = new Init();
    }
}
