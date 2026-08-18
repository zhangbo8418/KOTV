package com.bobo.kotv.host;

import android.app.Activity;
import android.content.Context;
import android.content.ContextWrapper;
import android.graphics.Bitmap;
import android.graphics.drawable.BitmapDrawable;
import android.graphics.drawable.Drawable;
import android.text.InputType;
import android.util.Base64;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.TextView;

import com.github.catvod.crawler.SpiderDebug;
import com.github.catvod.utils.Json;
import com.github.catvod.utils.UiBridge;
import com.github.catvod.utils.Util;

import java.io.ByteArrayOutputStream;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.util.ArrayList;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/**
 * 安卓当后端、其它端连过来用 TV dex jar 时：AlertDialog 会弹在手机 Activity 上，远端看不见。
 * 拦截 FLAG_DIM_BEHIND / 附着对话框的 addView，扫控件拼成 {@link UiBridge} 文档发到对应 client。
 */
public final class DialogRelay {

    private static final Set<View> SWALLOWED =
            Collections.newSetFromMap(new IdentityHashMap<>());
    private static final ExecutorService RELAY = Executors.newCachedThreadPool(r -> {
        Thread t = new Thread(r, "kotv-dialog-relay");
        t.setDaemon(true);
        return t;
    });

    private DialogRelay() {
    }

    /** 远端调用期间把 Activity/Context 包一层，WindowManager 走中继。 */
    public static Context maybeWrap(Context ctx) {
        if (ctx == null || !Util.hasRemoteUi()) return ctx;
        if (ctx instanceof RemoteUiContext) return ctx;
        Activity act = UiContext.activity();
        Context base = act != null ? act : ctx;
        if (base.getApplicationContext() == base) return ctx;
        return wrap(base, Util.remoteClientId(), Util.remoteUserId());
    }

    public static Context wrap(Context base, String clientId, String userId) {
        if (base == null) return null;
        if (base instanceof RemoteUiContext) return base;
        return new RemoteUiContext(base, clientId == null ? "" : clientId, userId == null ? "" : userId);
    }

    public static WindowManager wrapWindowManager(WindowManager real) {
        if (real == null) return null;
        if (Proxy.isProxyClass(real.getClass())) return real;
        return (WindowManager) Proxy.newProxyInstance(
                WindowManager.class.getClassLoader(),
                new Class<?>[]{WindowManager.class},
                new WmHandler(real));
    }

    public static boolean swallowRemove(View view) {
        if (view == null) return false;
        synchronized (SWALLOWED) {
            return SWALLOWED.remove(view);
        }
    }

    public static boolean isSwallowed(View view) {
        if (view == null) return false;
        synchronized (SWALLOWED) {
            return SWALLOWED.contains(view);
        }
    }

    static boolean tryRelay(View view, WindowManager.LayoutParams lp) {
        if (view == null || lp == null) return false;
        String cn = view.getClass().getName();
        if (cn.startsWith("io.flutter.")) return false;
        String cid = clientIdOf(view);
        if (cid.isEmpty()) return false;
        boolean toast = lp.type == WindowManager.LayoutParams.TYPE_TOAST;
        boolean dialog = (lp.flags & WindowManager.LayoutParams.FLAG_DIM_BEHIND) != 0
                || lp.type == WindowManager.LayoutParams.TYPE_APPLICATION_ATTACHED_DIALOG;
        if (!toast && !dialog) return false;
        synchronized (SWALLOWED) {
            SWALLOWED.add(view);
        }
        String uid = userIdOf(view);
        RELAY.execute(() -> runRelay(view, cid, uid, toast));
        return true;
    }

    private static void runRelay(View view, String clientId, String userId, boolean toast) {
        Util.setClientId(clientId);
        Util.setUserId(userId);
        try {
            if (toast) {
                sleepQuiet(80);
                String text = firstText(scanOnMain(view));
                if (!text.isEmpty()) Util.notify(text);
                return;
            }
            Snap snap = waitForContent(view);
            if (snap == null) return;
            UiBridge.Document doc = toDocument(snap);
            String kind = "jar-dialog-" + Integer.toHexString(System.identityHashCode(view));
            try {
                UiBridge.show(kind, doc);
                waitAndApply(kind, snap);
            } catch (Throwable t) {
                SpiderDebug.log("DialogRelay show: " + t.getMessage());
            }
        } finally {
            Util.clearScope();
        }
    }

    private static Snap waitForContent(View view) {
        sleepQuiet(280);
        Snap snap = scanOnMain(view);
        for (int i = 0; i < 8; i++) {
            if (snap != null && (!snap.images.isEmpty() || !emptyImageOnMain(view))) break;
            sleepQuiet(250);
            snap = scanOnMain(view);
        }
        return snap;
    }

    private static void sleepQuiet(long ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    private static boolean emptyImageOnMain(View view) {
        boolean[] empty = {false};
        runOnMain(view, () -> empty[0] = findEmptyImage(view));
        return empty[0];
    }

    private static Snap scanOnMain(View view) {
        AtomicReference<Snap> ref = new AtomicReference<>();
        runOnMain(view, () -> ref.set(scan(view)));
        return ref.get();
    }

    private static void runOnMain(View view, Runnable r) {
        CountDownLatch latch = new CountDownLatch(1);
        Runnable wrap = () -> {
            try {
                r.run();
            } finally {
                latch.countDown();
            }
        };
        Activity act = UiContext.activity();
        if (act != null) act.runOnUiThread(wrap);
        else view.post(wrap);
        try {
            latch.await(800, TimeUnit.MILLISECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    private static boolean findEmptyImage(View view) {
        if (view instanceof ImageView) {
            return ((ImageView) view).getDrawable() == null;
        }
        if (view instanceof ViewGroup) {
            ViewGroup g = (ViewGroup) view;
            for (int i = 0; i < g.getChildCount(); i++) {
                if (findEmptyImage(g.getChildAt(i))) return true;
            }
        }
        return false;
    }

    private static Snap scan(View root) {
        Snap snap = new Snap();
        walk(root, snap);
        View title = root.findViewById(android.R.id.title);
        if (title instanceof TextView) {
            snap.title = textOf((TextView) title);
        }
        View msg = root.findViewById(android.R.id.message);
        if (msg instanceof TextView) {
            snap.message = textOf((TextView) msg);
        }
        bindStdButton(root, android.R.id.button1, "positive", snap);
        bindStdButton(root, android.R.id.button2, "negative", snap);
        bindStdButton(root, android.R.id.button3, "neutral", snap);
        return snap;
    }

    private static void bindStdButton(View root, int id, String action, Snap snap) {
        View v = root.findViewById(id);
        if (!(v instanceof Button)) return;
        Button b = (Button) v;
        String label = textOf(b);
        if (label.isEmpty()) return;
        for (BtnSnap existing : snap.buttons) {
            if (existing.view == b) {
                existing.id = action;
                return;
            }
        }
        snap.buttons.add(new BtnSnap(action, label, b));
    }

    private static void walk(View view, Snap snap) {
        if (view == null || view.getVisibility() != View.VISIBLE) return;
        if (view instanceof EditText) {
            EditText e = (EditText) view;
            String id = "input" + snap.inputs.size();
            boolean password = (e.getInputType() & InputType.TYPE_TEXT_VARIATION_PASSWORD) != 0
                    || (e.getInputType() & InputType.TYPE_NUMBER_VARIATION_PASSWORD) != 0;
            snap.inputs.add(new InputSnap(id, hintOf(e), textOf(e), password, e));
            return;
        }
        if (view instanceof Button) {
            Button b = (Button) view;
            String label = textOf(b);
            if (!label.isEmpty()) {
                boolean dup = false;
                for (BtnSnap existing : snap.buttons) {
                    if (existing.view == b) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) snap.buttons.add(new BtnSnap("btn" + snap.buttons.size(), label, b));
            }
            return;
        }
        if (view instanceof ImageView) {
            String uri = imageUri((ImageView) view);
            if (!uri.isEmpty()) snap.images.add(uri);
            return;
        }
        if (view instanceof TextView) {
            String t = textOf((TextView) view);
            if (!t.isEmpty() && snap.texts.size() < 24) snap.texts.add(t);
        }
        if (view instanceof ViewGroup) {
            ViewGroup g = (ViewGroup) view;
            int n = Math.min(g.getChildCount(), 64);
            for (int i = 0; i < n; i++) walk(g.getChildAt(i), snap);
        }
    }

    private static UiBridge.Document toDocument(Snap snap) {
        UiBridge.Document doc = new UiBridge.Document();
        doc.title(snap.title == null ? "" : snap.title);
        doc.timeoutMs(180_000);
        if (snap.message != null && !snap.message.isEmpty()) doc.text(snap.message);
        for (String t : snap.texts) {
            if (t.equals(snap.title) || t.equals(snap.message)) continue;
            boolean btn = false;
            for (BtnSnap b : snap.buttons) {
                if (t.equals(b.label)) {
                    btn = true;
                    break;
                }
            }
            if (!btn) doc.text(t);
        }
        for (String img : snap.images) {
            doc.image(img, 220, 220);
        }
        for (InputSnap in : snap.inputs) {
            if (in.password) doc.password(in.id, in.hint);
            else doc.input(in.id, in.hint, false, in.value);
        }
        if (snap.buttons.isEmpty()) {
            doc.action("dismiss", "关闭", true);
        } else {
            for (int i = 0; i < snap.buttons.size(); i++) {
                BtnSnap b = snap.buttons.get(i);
                doc.action(b.id, b.label, true);
            }
        }
        return doc;
    }

    @SuppressWarnings("unchecked")
    private static void waitAndApply(String kind, Snap snap) {
        String session = UiBridge.currentSession(kind);
        if (session.isEmpty()) return;
        long deadline = System.currentTimeMillis() + 180_000;
        while (System.currentTimeMillis() < deadline) {
            String raw = Util.takeUiReplyRaw(session);
            String action = Util.uiReplyAction(raw).toLowerCase();
            if (action.isEmpty() || "shown".equals(action)) {
                try {
                    Thread.sleep(120);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    return;
                }
                continue;
            }
            Map<String, String> values = valuesOf(raw);
            if ("closed".equals(action) || "dismiss".equals(action) || "timeout".equals(action)
                    || "cancel".equals(action)) {
                clickNamed(snap, "negative", values);
                return;
            }
            clickNamed(snap, action, values);
            return;
        }
    }

    @SuppressWarnings("unchecked")
    private static Map<String, String> valuesOf(String raw) {
        Map<String, String> out = new java.util.LinkedHashMap<>();
        if (raw == null || !raw.trim().startsWith("{")) return out;
        Map<String, Object> event = Json.parseSafe(raw.trim(), Map.class);
        if (event == null) return out;
        Object valuesObj = event.get("values");
        if (!(valuesObj instanceof Map)) return out;
        for (Map.Entry<?, ?> e : ((Map<?, ?>) valuesObj).entrySet()) {
            if (e.getKey() == null || e.getValue() == null) continue;
            out.put(String.valueOf(e.getKey()), String.valueOf(e.getValue()));
        }
        return out;
    }

    private static void clickNamed(Snap snap, String action, Map<String, String> values) {
        BtnSnap target = null;
        for (BtnSnap b : snap.buttons) {
            if (action.equalsIgnoreCase(b.id) || action.equalsIgnoreCase(b.label)) {
                target = b;
                break;
            }
        }
        if (target == null && "negative".equals(action)) {
            for (BtnSnap b : snap.buttons) {
                if (b.label.contains("取消") || b.label.contains("关闭") || "negative".equals(b.id)) {
                    target = b;
                    break;
                }
            }
        }
        if (target == null && !snap.buttons.isEmpty() && !"negative".equals(action) && !"dismiss".equals(action)) {
            target = snap.buttons.get(0);
        }
        final BtnSnap click = target;
        Activity act = UiContext.activity();
        Runnable apply = () -> {
            for (InputSnap in : snap.inputs) {
                String v = values.get(in.id);
                if (v != null && in.view != null) in.view.setText(v);
            }
            if (click != null && click.view != null) {
                click.view.performClick();
            }
        };
        if (act != null) act.runOnUiThread(apply);
        else apply.run();
    }

    private static String firstText(Snap snap) {
        if (snap == null) return "";
        if (snap.message != null && !snap.message.isEmpty()) return snap.message;
        if (snap.title != null && !snap.title.isEmpty()) return snap.title;
        return snap.texts.isEmpty() ? "" : snap.texts.get(0);
    }

    private static String textOf(TextView tv) {
        CharSequence cs = tv.getText();
        return cs == null ? "" : cs.toString().trim();
    }

    private static String hintOf(EditText e) {
        CharSequence cs = e.getHint();
        return cs == null ? "" : cs.toString().trim();
    }

    private static String imageUri(ImageView iv) {
        Drawable d = iv.getDrawable();
        if (!(d instanceof BitmapDrawable)) return "";
        Bitmap bm = ((BitmapDrawable) d).getBitmap();
        if (bm == null || bm.isRecycled()) return "";
        try {
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            Bitmap scaled = bm;
            int w = bm.getWidth();
            int h = bm.getHeight();
            if (w > 360 || h > 360) {
                float s = Math.min(360f / w, 360f / h);
                scaled = Bitmap.createScaledBitmap(bm, Math.max(1, (int) (w * s)), Math.max(1, (int) (h * s)), true);
            }
            scaled.compress(Bitmap.CompressFormat.PNG, 90, bos);
            if (scaled != bm && !scaled.isRecycled()) scaled.recycle();
            return "data:image/png;base64," + Base64.encodeToString(bos.toByteArray(), Base64.NO_WRAP);
        } catch (Throwable t) {
            return "";
        }
    }

    private static String clientIdOf(View view) {
        Context c = view.getContext();
        int hops = 0;
        while (c instanceof ContextWrapper && hops++ < 8) {
            if (c instanceof RemoteUiContext) return ((RemoteUiContext) c).clientId;
            c = ((ContextWrapper) c).getBaseContext();
        }
        return Util.remoteClientId();
    }

    private static String userIdOf(View view) {
        Context c = view.getContext();
        int hops = 0;
        while (c instanceof ContextWrapper && hops++ < 8) {
            if (c instanceof RemoteUiContext) return ((RemoteUiContext) c).userId;
            c = ((ContextWrapper) c).getBaseContext();
        }
        return Util.remoteUserId();
    }

    static final class RemoteUiContext extends ContextWrapper {
        final String clientId;
        final String userId;
        private WindowManager wm;

        RemoteUiContext(Context base, String clientId, String userId) {
            super(base);
            this.clientId = clientId;
            this.userId = userId;
        }

        @Override
        public Object getSystemService(String name) {
            Object s = super.getSystemService(name);
            if (WINDOW_SERVICE.equals(name) && s instanceof WindowManager) {
                synchronized (this) {
                    if (wm == null) wm = wrapWindowManager((WindowManager) s);
                    return wm;
                }
            }
            return s;
        }
    }

    private static final class WmHandler implements InvocationHandler {
        private final WindowManager real;

        WmHandler(WindowManager real) {
            this.real = real;
        }

        @Override
        public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
            if (args == null) args = new Object[0];
            String name = method.getName();
            if (args.length == 0 && "hashCode".equals(name)) return System.identityHashCode(proxy);
            if (args.length == 1 && "equals".equals(name)) return proxy == args[0];
            if (args.length == 0 && "toString".equals(name)) return "KotvRelayingWindowManager";
            if ("addView".equals(name) && args.length >= 2 && args[0] instanceof View
                    && args[1] instanceof WindowManager.LayoutParams) {
                if (tryRelay((View) args[0], (WindowManager.LayoutParams) args[1])) return null;
            }
            if (("removeView".equals(name) || "removeViewImmediate".equals(name))
                    && args.length >= 1 && args[0] instanceof View) {
                if (swallowRemove((View) args[0])) return null;
            }
            if ("updateViewLayout".equals(name) && args.length >= 1 && args[0] instanceof View) {
                if (isSwallowed((View) args[0])) return null;
            }
            try {
                return method.invoke(real, args);
            } catch (InvocationTargetException e) {
                Throwable c = e.getCause();
                throw c != null ? c : e;
            }
        }
    }

    private static final class Snap {
        String title = "";
        String message = "";
        final List<String> texts = new ArrayList<>();
        final List<String> images = new ArrayList<>();
        final List<InputSnap> inputs = new ArrayList<>();
        final List<BtnSnap> buttons = new ArrayList<>();
    }

    private static final class InputSnap {
        final String id;
        final String hint;
        final String value;
        final boolean password;
        final EditText view;

        InputSnap(String id, String hint, String value, boolean password, EditText view) {
            this.id = id;
            this.hint = hint;
            this.value = value;
            this.password = password;
            this.view = view;
        }
    }

    private static final class BtnSnap {
        String id;
        final String label;
        final Button view;

        BtnSnap(String id, String label, Button view) {
            this.id = id;
            this.label = label;
            this.view = view;
        }
    }
}
