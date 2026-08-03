package com.github.catvod.utils;

import com.github.catvod.crawler.SpiderDebug;
import com.google.zxing.BarcodeFormat;
import com.google.zxing.EncodeHintType;
import com.google.zxing.MultiFormatWriter;
import com.google.zxing.common.BitMatrix;
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.EnumMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Consumer;
import java.util.zip.CRC32;
import java.util.zip.Deflater;

/**
 * Jar-owned declarative UI. Host renders a frozen primitive set only;
 * all layout and business meaning live here.
 *
 * <p>Frozen host element types: text, image, input, checkbox, radio, select, button,
 * link, progress, separator, spacer, space, row, column, group. Document actions become bottom buttons.
 * Host renders primitives only; titles, copy, size, timeout and URLs all come from this document.
 */
public final class UiBridge {

    public interface Handle {
        void dispose();
    }

    /** Host handshake failed (shown/closed timeout or post failed). */
    public static final class ShowFailedException extends RuntimeException {
        public ShowFailedException(String message) {
            super(message);
        }
    }

    /** One option for radio / select. */
    public static final class Option {
        public final String id;
        public final String label;

        public Option(String id, String label) {
            this.id = id == null ? "" : id;
            this.label = label == null || label.trim().isEmpty() ? this.id : label;
        }

        public static Option of(String id) {
            return new Option(id, id);
        }

        public static Option of(String id, String label) {
            return new Option(id, label);
        }
    }

    /**
     * Mutable element list for a document or nested layout block.
     */
    public static final class Elements {
        private final List<Map<String, Object>> target;

        Elements(List<Map<String, Object>> target) {
            this.target = target;
        }

        public Elements text(String text) {
            addText(target, text);
            return this;
        }

        public Elements image(String source, int width, int height) {
            addImage(target, source, width, height);
            return this;
        }

        public Elements input(String id, String placeholder, boolean multiline) {
            addInput(target, id, placeholder, multiline, false, "");
            return this;
        }

        public Elements input(String id, String placeholder, boolean multiline, String value) {
            addInput(target, id, placeholder, multiline, false, value);
            return this;
        }

        public Elements password(String id, String placeholder) {
            addInput(target, id, placeholder, false, true, "");
            return this;
        }

        public Elements checkbox(String id, String text, boolean checked) {
            Map<String, Object> element = new LinkedHashMap<>();
            element.put("type", "checkbox");
            element.put("id", id);
            element.put("text", text == null ? "" : text);
            element.put("checked", checked);
            target.add(element);
            return this;
        }

        public Elements radio(String id, String selected, Option... options) {
            return radio(id, selected, options == null ? Collections.emptyList() : Arrays.asList(options));
        }

        public Elements radio(String id, String selected, List<Option> options) {
            Map<String, Object> element = new LinkedHashMap<>();
            element.put("type", "radio");
            element.put("id", id);
            if (selected != null) element.put("value", selected);
            element.put("options", toOptionMaps(options));
            target.add(element);
            return this;
        }

        public Elements select(String id, String selected, Option... options) {
            return select(id, selected, options == null ? Collections.emptyList() : Arrays.asList(options));
        }

        public Elements select(String id, String selected, List<Option> options) {
            Map<String, Object> element = new LinkedHashMap<>();
            element.put("type", "select");
            element.put("id", id);
            if (selected != null) element.put("value", selected);
            element.put("options", toOptionMaps(options));
            target.add(element);
            return this;
        }

        public Elements button(String id, String label) {
            return button(id, label, false);
        }

        public Elements button(String id, String label, boolean dismiss) {
            Map<String, Object> element = new LinkedHashMap<>();
            element.put("type", "button");
            element.put("id", id);
            element.put("text", label == null ? "" : label);
            element.put("dismiss", dismiss);
            target.add(element);
            return this;
        }

        /**
         * Openable URL / deep link. Host opens via system handler (browser or app scheme).
         * @param style {@code text} (default) or {@code button}
         */
        public Elements link(String text, String url) {
            return link(text, url, "text");
        }

        public Elements link(String text, String url, String style) {
            if (url == null || url.trim().isEmpty()) return this;
            Map<String, Object> element = new LinkedHashMap<>();
            element.put("type", "link");
            element.put("text", text == null || text.trim().isEmpty() ? url : text);
            element.put("url", url.trim());
            if (style != null && !style.trim().isEmpty()) element.put("style", style.trim());
            target.add(element);
            return this;
        }

        public Elements separator() {
            Map<String, Object> element = new LinkedHashMap<>();
            element.put("type", "separator");
            target.add(element);
            return this;
        }

        public Elements spacer(int height) {
            Map<String, Object> element = new LinkedHashMap<>();
            element.put("type", "spacer");
            element.put("height", height <= 0 ? 8 : height);
            target.add(element);
            return this;
        }

        /** Indeterminate progress indicator; host draws chrome only, no caption. */
        public Elements progress() {
            Map<String, Object> element = new LinkedHashMap<>();
            element.put("type", "progress");
            target.add(element);
            return this;
        }

        public Elements space() {
            Map<String, Object> element = new LinkedHashMap<>();
            element.put("type", "space");
            target.add(element);
            return this;
        }

        public Elements row(Consumer<Elements> block) {
            return row(0, block);
        }

        public Elements row(int spacing, Consumer<Elements> block) {
            addLayout(target, "row", null, spacing, block);
            return this;
        }

        public Elements column(Consumer<Elements> block) {
            return column(0, block);
        }

        public Elements column(int spacing, Consumer<Elements> block) {
            addLayout(target, "column", null, spacing, block);
            return this;
        }

        public Elements group(String title, Consumer<Elements> block) {
            return group(title, 0, block);
        }

        public Elements group(String title, int spacing, Consumer<Elements> block) {
            addLayout(target, "group", title, spacing, block);
            return this;
        }
    }

    /**
     * Declarative window builder. Compose with add* then {@link #show(String, Document)}.
     */
    public static final class Document {
        public String title = "提示";
        public int width = 420;
        public int height = 560;
        public long timeoutMs = 120_000;
        public final List<Map<String, Object>> elements = new ArrayList<>();
        public final List<Map<String, Object>> actions = new ArrayList<>();
        private final Elements els = new Elements(elements);

        public Document title(String title) {
            if (title != null && !title.trim().isEmpty()) this.title = title;
            return this;
        }

        public Document size(int width, int height) {
            if (width > 0) this.width = width;
            if (height > 0) this.height = height;
            return this;
        }

        public Document timeoutMs(long timeoutMs) {
            this.timeoutMs = timeoutMs;
            return this;
        }

        public Document text(String text) {
            els.text(text);
            return this;
        }

        public Document image(String source, int width, int height) {
            els.image(source, width, height);
            return this;
        }

        public Document input(String id, String placeholder, boolean multiline) {
            els.input(id, placeholder, multiline);
            return this;
        }

        public Document input(String id, String placeholder, boolean multiline, String value) {
            els.input(id, placeholder, multiline, value);
            return this;
        }

        public Document password(String id, String placeholder) {
            els.password(id, placeholder);
            return this;
        }

        public Document checkbox(String id, String text, boolean checked) {
            els.checkbox(id, text, checked);
            return this;
        }

        public Document radio(String id, String selected, Option... options) {
            els.radio(id, selected, options);
            return this;
        }

        public Document radio(String id, String selected, List<Option> options) {
            els.radio(id, selected, options);
            return this;
        }

        public Document select(String id, String selected, Option... options) {
            els.select(id, selected, options);
            return this;
        }

        public Document select(String id, String selected, List<Option> options) {
            els.select(id, selected, options);
            return this;
        }

        public Document button(String id, String label) {
            els.button(id, label);
            return this;
        }

        public Document button(String id, String label, boolean dismiss) {
            els.button(id, label, dismiss);
            return this;
        }

        public Document link(String text, String url) {
            els.link(text, url);
            return this;
        }

        public Document link(String text, String url, String style) {
            els.link(text, url, style);
            return this;
        }

        public Document separator() {
            els.separator();
            return this;
        }

        public Document spacer(int height) {
            els.spacer(height);
            return this;
        }

        public Document progress() {
            els.progress();
            return this;
        }

        public Document space() {
            els.space();
            return this;
        }

        public Document row(Consumer<Elements> block) {
            els.row(block);
            return this;
        }

        public Document row(int spacing, Consumer<Elements> block) {
            els.row(spacing, block);
            return this;
        }

        public Document column(Consumer<Elements> block) {
            els.column(block);
            return this;
        }

        public Document column(int spacing, Consumer<Elements> block) {
            els.column(spacing, block);
            return this;
        }

        public Document group(String title, Consumer<Elements> block) {
            els.group(title, block);
            return this;
        }

        public Document group(String title, int spacing, Consumer<Elements> block) {
            els.group(title, spacing, block);
            return this;
        }

        public Document action(String id, String label, boolean dismiss) {
            actions.add(UiBridge.action(id, label, dismiss));
            return this;
        }

        public Document defaultActions() {
            actions.addAll(UiBridge.defaultActions());
            return this;
        }
    }

    private static final ConcurrentHashMap<String, String> sessionByKind = new ConcurrentHashMap<>();
    private static final ConcurrentHashMap<String, Runnable> cancelBySession = new ConcurrentHashMap<>();
    private static final ConcurrentHashMap<String, Consumer<String>> submitBySession = new ConcurrentHashMap<>();
    private static final ConcurrentHashMap<String, Runnable> qrBySession = new ConcurrentHashMap<>();
    private static final AtomicLong nextSession = new AtomicLong();

    private UiBridge() {
    }

    /** Show an arbitrary document under an internal kind key (opaque session to host). */
    public static Handle show(String kind, Document document) {
        return show(kind, document, null, null);
    }

    public static Handle show(String kind, Document document, Consumer<String> onSubmitValue, Runnable onCancel) {
        String k = normalizeKind(kind);
        String session;
        try {
            session = openSession(k);
        } catch (ShowFailedException e) {
            SpiderDebug.log("UiBridge openSession: " + e.getMessage());
            Util.notify("弹窗关闭确认超时，请重试");
            throw e;
        }
        if (onCancel != null) registerCancel(session, onCancel);
        if (onSubmitValue != null) submitBySession.put(session, onSubmitValue);
        Document doc = document == null ? new Document() : document;
        if (doc.actions.isEmpty()) doc.defaultActions();
        try {
            showDocument(session, doc);
        } catch (ShowFailedException e) {
            SpiderDebug.log("UiBridge showDocument: " + e.getMessage());
            cancelBySession.remove(session);
            submitBySession.remove(session);
            qrBySession.remove(session);
            sessionByKind.remove(k, session);
            // 尝试关掉可能半开的窗，再等 closed（不 bump epoch，以免吞掉 CLOSE）。
            closeDocument(session);
            Util.waitUiAction(session, "closed", Util.UI_CLOSE_WAIT_MS);
            Util.notify("弹窗未能显示，请重试");
            throw e;
        }
        return handleFor(k, session);
    }

    public static Handle showQrContent(String content, String title, String tip, Runnable onCancel) {
        return showQrContent(guessKind(title, tip), content, title, tip, onCancel);
    }

    public static Handle showQrContent(String kind, String content, String title, String tip, Runnable onCancel) {
        Document doc = new Document().title(title).text(tip).timeoutMs(180_000);
        String image = encodeQrDataUri(content);
        if (!image.isEmpty()) doc.image(image, 260, 260);
        else if (content != null && !content.trim().isEmpty()) doc.text(content);
        if (looksLikeOpenableUrl(content)) {
            doc.link("在 App / 浏览器打开", content.trim(), "button");
        }
        doc.input("value", "粘贴凭证", true).defaultActions();
        return show(kind, doc, null, onCancel);
    }

    public static Handle showQrBase64(String base64, String title, String tip, Runnable onCancel) {
        return showQrBase64(guessKind(title, tip), base64, title, tip, onCancel);
    }

    public static Handle showQrBase64(String kind, String base64, String title, String tip, Runnable onCancel) {
        Document doc = new Document().title(title).text(tip).timeoutMs(180_000);
        String image = dataUri(base64);
        if (!image.isEmpty()) doc.image(image, 260, 260);
        doc.input("value", "粘贴凭证", true).defaultActions();
        return show(kind, doc, null, onCancel);
    }

    /** 拉取二维码 token 前显示加载窗（可与拉码并行）；同 kind 再 show 时会先等旧窗 closed 再开新窗。 */
    public static Handle showFetchQrLoading(String kind, String title, Runnable onCancel) {
        Document doc = new Document()
                .title(title)
                .size(360, 220)
                .timeoutMs(45_000)
                .progress()
                .spacer(12)
                .text("正在获取二维码，请稍候…")
                .action("cancel", "取消", true);
        return show(kind, doc, null, onCancel);
    }

    /** 拉码失败：关窗并提示。 */
    public static void failFetchQr(String kind, String message) {
        String k = normalizeKind(kind);
        String session = currentSession(k);
        if (!session.isEmpty()) {
            cancelBySession.remove(session);
            submitBySession.remove(session);
            qrBySession.remove(session);
            sessionByKind.remove(k, session);
            // 先发 CLOSE 并等 closed；不要在等待前 bump epoch（会吞掉 CLOSE）。
            closeDocument(session);
            Util.waitUiAction(session, "closed", Util.UI_CLOSE_WAIT_MS);
            Util.clearPendingUiNotify();
        } else {
            Util.clearPendingUiNotify();
        }
        if (message != null && !message.trim().isEmpty()) Util.notify(message);
    }

    public static Handle showTokenInput(String title, String tip, Consumer<String> onOk, Runnable onQr) {
        return showTokenInput(title, tip, onOk, onQr, null);
    }

    public static Handle showTokenInput(String title, String tip, Consumer<String> onOk, Runnable onQr, Runnable onCancel) {
        String kind = normalizeKind(guessKind(title, tip));
        Document doc = new Document()
                .title(title)
                .text(tip)
                .input("value", "请输入内容", true)
                .action("submit", "确认", true)
                .action("qrcode", "扫码登录", false)
                .action("cancel", "关闭", true);
        Handle handle = show(kind, doc, onOk, onCancel);
        if (onQr != null) {
            String session = currentSession(kind);
            if (!session.isEmpty()) qrBySession.put(session, onQr);
        }
        return handle;
    }

    /** Dispatches a normalized event returned by {@link Util#takeUiReply(String)}. */
    public static void dispatchHostReply(String session, String reply) {
        if (session == null || session.isEmpty() || reply == null || reply.isEmpty()) return;
        if ("QRCODE".equals(reply)) {
            Runnable qr = qrBySession.get(session);
            if (qr != null) {
                try {
                    qr.run();
                } catch (Throwable t) {
                    SpiderDebug.log("UiBridge qrcode: " + t.getMessage());
                }
            }
            return;
        }
        if ("CANCEL".equals(reply)) {
            clearSession(session);
            Util.clearPendingUiNotify();
            qrBySession.remove(session);
            Runnable cancel = cancelBySession.remove(session);
            submitBySession.remove(session);
            if (cancel != null) {
                try {
                    cancel.run();
                } catch (Throwable t) {
                    SpiderDebug.log("UiBridge cancel: " + t.getMessage());
                }
            }
            return;
        }
        if (reply.startsWith("SUBMIT:")) {
            clearSession(session);
            qrBySession.remove(session);
            String value = reply.substring(7).trim();
            Consumer<String> submit = submitBySession.remove(session);
            cancelBySession.remove(session);
            if (submit != null && !value.isEmpty()) {
                try {
                    submit.accept(value);
                } catch (Throwable t) {
                    SpiderDebug.log("UiBridge submit: " + t.getMessage());
                }
            }
        }
    }

    /** True while a host window session is open for this business kind. */
    public static boolean hasSession(String kind) {
        return !currentSession(kind).isEmpty();
    }

    /**
     * 当前 kind 弹窗对应的客户端平台（android/ios/…）。
     * 以 Flutter 前端为准；按 session 隔离，多前端不会串台。
     * 须在 {@code show}/{@code shown} 握手成功后读取。
     */
    public static String hostPlatform(String kind) {
        return Util.hostPlatform(currentSession(kind));
    }

    public static boolean hostDesktop(String kind) {
        return Util.hostDesktop(currentSession(kind));
    }

    /** @deprecated 请用 {@link #hostPlatform(String kind)}，避免多前端串台 */
    @Deprecated
    public static String hostPlatform() {
        return "";
    }

    /** @deprecated 请用 {@link #hostDesktop(String kind)} */
    @Deprecated
    public static boolean hostDesktop() {
        return false;
    }

    /**
     * 等宿主登录窗结局（shown/closed 握手）。
     * 认 {@code CLOSED}/{@code CANCEL}/{@code SUBMIT:}；不再用 hasSession 消失猜关窗（会与换窗竞态）。
     *
     * @param done 已登录成功则结束等待并返回空串
     * @return {@code CANCEL} / {@code CLOSED} / {@code SUBMIT:...} / {@code TIMEOUT} / {@code ""}（done）
     */
    public static String waitHostLoginReply(String kind, long timeoutMs, java.util.function.BooleanSupplier done) {
        String k = normalizeKind(kind);
        if (done == null) done = () -> false;
        long deadline = System.currentTimeMillis() + Math.max(1_000L, timeoutMs);
        while (!done.getAsBoolean() && System.currentTimeMillis() < deadline) {
            String reply = Util.takeUiReply(k);
            // QRCODE 已由 takeUiReply → dispatchHostReply 触发扫码；继续等结局。
            if ("CLOSED".equals(reply)) return "CLOSED";
            if ("CANCEL".equals(reply)) return "CANCEL";
            if (reply != null && reply.startsWith("SUBMIT:")) return reply;
            try {
                Thread.sleep(250);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return "CANCEL";
            }
        }
        if (done.getAsBoolean()) {
            // 登录已成功：脚本侧必须主动关宿主窗（宿主不管业务，不会自己猜关）。
            String session = currentSession(k);
            if (!session.isEmpty()) {
                cancelBySession.remove(session);
                submitBySession.remove(session);
                qrBySession.remove(session);
                sessionByKind.remove(k, session);
                closeDocument(session);
                Util.waitUiAction(session, "closed", Util.UI_CLOSE_WAIT_MS);
                Util.clearPendingUiNotify();
            }
            return "";
        }
        return "TIMEOUT";
    }

    private static void clearSession(String session) {
        if (session == null || session.isEmpty()) return;
        for (Map.Entry<String, String> e : sessionByKind.entrySet()) {
            if (session.equals(e.getValue())) {
                sessionByKind.remove(e.getKey(), session);
                break;
            }
        }
        Util.clearHostClientInfo(session);
    }

    public static void dispose(Handle handle) {
        if (handle == null) return;
        try {
            handle.dispose();
        } catch (Throwable ignored) {
        }
    }

    public static void showToast(String msg, int timeMills) {
        Util.notify(msg == null ? "" : msg);
    }

    public static String guessKind(String title, String tip) {
        String s = ((title == null ? "" : title) + " " + (tip == null ? "" : tip)).toLowerCase();
        if (s.contains("quark") || s.contains("夸克")) return "quark";
        if (s.contains("uc")) return "uc";
        if (s.contains("ali") || s.contains("阿里")) return "ali";
        return "login";
    }

    /** Business code uses its internal key; only the opaque session id crosses the host boundary. */
    public static String currentSession(String kind) {
        return sessionByKind.getOrDefault(normalizeKind(kind), "");
    }

    private static String openSession(String kind) {
        String session = "ui-" + Long.toUnsignedString(nextSession.incrementAndGet(), 36)
                + "-" + Long.toUnsignedString(System.nanoTime(), 36);
        String previous = sessionByKind.put(kind, session);
        if (previous != null && !previous.equals(session)) {
            cancelBySession.remove(previous);
            submitBySession.remove(previous);
            qrBySession.remove(previous);
            // 关旧窗并等宿主 closed，再开新窗（不再依赖宿主原地换内容）。
            closeDocument(previous);
            if (!Util.waitUiAction(previous, "closed", Util.UI_CLOSE_WAIT_MS)) {
                sessionByKind.remove(kind, session);
                throw new ShowFailedException("wait closed timeout for " + previous);
            }
        }
        return session;
    }

    private static void showDocument(String session, Document doc) {
        Map<String, Object> document = new LinkedHashMap<>();
        document.put("id", session);
        document.put("title", doc.title == null || doc.title.trim().isEmpty() ? "提示" : doc.title);
        document.put("width", doc.width);
        document.put("height", doc.height);
        document.put("timeoutMs", doc.timeoutMs);
        document.put("elements", doc.elements);
        document.put("actions", doc.actions);
        Util.notifySync("UI:" + Json.toJson(document));
        if (!Util.waitUiAction(session, "shown", Util.UI_HANDSHAKE_MS)) {
            throw new ShowFailedException("wait shown timeout for " + session);
        }
    }

    private static void closeDocument(String session) {
        Map<String, Object> command = new LinkedHashMap<>();
        command.put("id", session);
        Util.notifySync("UI_CLOSE:" + Json.toJson(command));
    }

    private static void addLayout(List<Map<String, Object>> target, String type, String title,
                                  int spacing, Consumer<Elements> block) {
        List<Map<String, Object>> children = new ArrayList<>();
        if (block != null) block.accept(new Elements(children));
        Map<String, Object> element = new LinkedHashMap<>();
        element.put("type", type);
        if (title != null && !title.trim().isEmpty()) element.put("text", title);
        if (spacing > 0) element.put("spacing", spacing);
        element.put("children", children);
        target.add(element);
    }

    private static void addText(List<Map<String, Object>> elements, String text) {
        if (text == null || text.trim().isEmpty()) return;
        Map<String, Object> element = new LinkedHashMap<>();
        element.put("type", "text");
        element.put("text", text);
        elements.add(element);
    }

    private static void addImage(List<Map<String, Object>> elements, String source, int width, int height) {
        if (source == null || source.trim().isEmpty()) return;
        Map<String, Object> element = new LinkedHashMap<>();
        element.put("type", "image");
        element.put("source", source);
        element.put("width", width);
        element.put("height", height);
        elements.add(element);
    }

    private static void addInput(List<Map<String, Object>> elements, String id, String placeholder,
                                 boolean multiline, boolean password, String value) {
        Map<String, Object> element = new LinkedHashMap<>();
        element.put("type", "input");
        element.put("id", id);
        element.put("placeholder", placeholder == null ? "" : placeholder);
        element.put("multiline", multiline);
        element.put("password", password);
        if (value != null && !value.isEmpty()) element.put("value", value);
        elements.add(element);
    }

    private static List<Map<String, Object>> toOptionMaps(List<Option> options) {
        List<Map<String, Object>> list = new ArrayList<>();
        if (options == null) return list;
        for (Option option : options) {
            if (option == null) continue;
            Map<String, Object> item = new LinkedHashMap<>();
            item.put("id", option.id);
            item.put("label", option.label);
            list.add(item);
        }
        return list;
    }

    private static List<Map<String, Object>> defaultActions() {
        List<Map<String, Object>> actions = new ArrayList<>();
        actions.add(action("submit", "确认", true));
        actions.add(action("cancel", "关闭", true));
        return actions;
    }

    private static Map<String, Object> action(String id, String label, boolean dismiss) {
        Map<String, Object> action = new LinkedHashMap<>();
        action.put("id", id);
        action.put("label", label);
        action.put("dismiss", dismiss);
        return action;
    }

    private static void registerCancel(String session, Runnable onCancel) {
        if (onCancel != null) cancelBySession.put(session, onCancel);
        else cancelBySession.remove(session);
    }

    private static Handle handleFor(String kind, String session) {
        return () -> {
            cancelBySession.remove(session);
            submitBySession.remove(session);
            qrBySession.remove(session);
            sessionByKind.remove(kind, session);
            // 先 CLOSE 再等 closed；成功后再清异步 toast 队列。
            closeDocument(session);
            Util.waitUiAction(session, "closed", Util.UI_CLOSE_WAIT_MS);
            Util.clearHostClientInfo(session);
            Util.clearPendingUiNotify();
        };
    }

    private static String normalizeKind(String kind) {
        if (kind == null || kind.trim().isEmpty()) return "login";
        return kind.trim().toLowerCase();
    }

    private static String dataUri(String base64) {
        if (base64 == null || base64.trim().isEmpty()) return "";
        String value = base64.trim();
        if (value.startsWith("data:")) return value;
        int marker = value.indexOf("base64,");
        if (marker >= 0) value = value.substring(marker + 7);
        return "data:image/png;base64," + value;
    }

    private static boolean looksLikeOpenableUrl(String raw) {
        if (raw == null) return false;
        String s = raw.trim().toLowerCase();
        if (s.isEmpty()) return false;
        return s.startsWith("http://") || s.startsWith("https://") || s.contains("://");
    }

    private static String encodeQrDataUri(String content) {
        if (content == null || content.trim().isEmpty()) return "";
        try {
            Map<EncodeHintType, Object> hints = new EnumMap<>(EncodeHintType.class);
            hints.put(EncodeHintType.CHARACTER_SET, "UTF-8");
            hints.put(EncodeHintType.ERROR_CORRECTION, ErrorCorrectionLevel.M);
            hints.put(EncodeHintType.MARGIN, 1);
            BitMatrix matrix = new MultiFormatWriter().encode(content, BarcodeFormat.QR_CODE, 0, 0, hints);
            byte[] png = matrixToPng(matrix, 5);
            return "data:image/png;base64," + Base64.getEncoder().encodeToString(png);
        } catch (Throwable e) {
            SpiderDebug.log("UiBridge image encode: " + e.getMessage());
            return "";
        }
    }

    private static byte[] matrixToPng(BitMatrix matrix, int scale) throws Exception {
        int width = matrix.getWidth() * scale;
        int height = matrix.getHeight() * scale;
        byte[] raw = new byte[width * height];
        for (int y = 0; y < matrix.getHeight(); y++) {
            for (int x = 0; x < matrix.getWidth(); x++) {
                byte color = (byte) (matrix.get(x, y) ? 0x00 : 0xFF);
                for (int dy = 0; dy < scale; dy++) {
                    int row = (y * scale + dy) * width;
                    for (int dx = 0; dx < scale; dx++) {
                        raw[row + x * scale + dx] = color;
                    }
                }
            }
        }

        byte[] ihdr = new byte[13];
        putInt(ihdr, 0, width);
        putInt(ihdr, 4, height);
        ihdr[8] = 8;
        ihdr[9] = 0;
        ihdr[10] = 0;
        ihdr[11] = 0;
        ihdr[12] = 0;

        byte[] scanlines = new byte[(width + 1) * height];
        for (int y = 0; y < height; y++) {
            int src = y * width;
            int dst = y * (width + 1);
            scanlines[dst] = 0;
            System.arraycopy(raw, src, scanlines, dst + 1, width);
        }
        Deflater deflater = new Deflater(Deflater.BEST_SPEED);
        deflater.setInput(scanlines);
        deflater.finish();
        ByteArrayOutputStream compressed = new ByteArrayOutputStream();
        byte[] buffer = new byte[4096];
        while (!deflater.finished()) {
            int count = deflater.deflate(buffer);
            compressed.write(buffer, 0, count);
        }
        deflater.end();

        ByteArrayOutputStream png = new ByteArrayOutputStream();
        png.write(new byte[]{(byte) 137, 80, 78, 71, 13, 10, 26, 10});
        writeChunk(png, "IHDR".getBytes(StandardCharsets.US_ASCII), ihdr);
        writeChunk(png, "IDAT".getBytes(StandardCharsets.US_ASCII), compressed.toByteArray());
        writeChunk(png, "IEND".getBytes(StandardCharsets.US_ASCII), new byte[0]);
        return png.toByteArray();
    }

    private static void writeChunk(ByteArrayOutputStream out, byte[] type, byte[] data) throws Exception {
        putIntBytes(out, data.length);
        out.write(type);
        out.write(data);
        CRC32 crc = new CRC32();
        crc.update(type);
        crc.update(data);
        putIntBytes(out, (int) crc.getValue());
    }

    private static void putInt(byte[] target, int offset, int value) {
        target[offset] = (byte) (value >>> 24);
        target[offset + 1] = (byte) (value >>> 16);
        target[offset + 2] = (byte) (value >>> 8);
        target[offset + 3] = (byte) value;
    }

    private static void putIntBytes(ByteArrayOutputStream out, int value) {
        out.write((value >>> 24) & 0xFF);
        out.write((value >>> 16) & 0xFF);
        out.write((value >>> 8) & 0xFF);
        out.write(value & 0xFF);
    }
}
