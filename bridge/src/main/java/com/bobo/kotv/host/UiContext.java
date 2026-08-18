package com.bobo.kotv.host;

import android.app.Activity;
import android.app.Application;
import android.content.Context;

import java.lang.ref.WeakReference;

/**
 * TV dex jar 弹窗需要 Activity window token；Application 单独用在 Flutter 壳上易 BadTokenException。
 * 由 {@code KotvApplication} 生命周期写入，{@code SpiderBridge} / jar Init 注入读取。
 */
public final class UiContext {

    private static volatile Application application;
    private static volatile WeakReference<Activity> activityRef = new WeakReference<>(null);

    private UiContext() {
    }

    public static void setApplication(Application app) {
        if (app != null) {
            application = app;
        }
    }

    public static void setActivity(Activity activity) {
        if (activity == null) {
            activityRef = new WeakReference<>(null);
            return;
        }
        activityRef = new WeakReference<>(activity);
    }

    public static Application application() {
        return application;
    }

    public static Activity activity() {
        Activity act = activityRef.get();
        if (act == null) {
            return null;
        }
        try {
            if (act.isFinishing() || act.isDestroyed()) {
                return null;
            }
        } catch (Throwable ignored) {
        }
        return act;
    }

    /** AlertDialog / Toast 优先 Activity，否则 Application。 */
    public static Context forUi() {
        Activity act = activity();
        if (act != null) {
            return act;
        }
        Application app = application;
        if (app != null) {
            return app;
        }
        return null;
    }
}
