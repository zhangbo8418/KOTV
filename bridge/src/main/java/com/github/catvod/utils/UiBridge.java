package com.github.catvod.utils;

import com.github.catvod.crawler.SpiderDebug;

import java.util.Collections;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Consumer;

/**
 * Declarative UI protocol for spider scripts. Host only renders frozen primitives and
 * reports shown/closed — it never interprets content (image vs anything else) or action ids.
 *
 * <p>Frozen host element types: text, image, input, checkbox, radio, select, button,
 * link, progress, separator, spacer, space, row, column, group.
 * Bridge: {@link #show}/{@link #close} handshake only; scripts own documents and replies.
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
            if (height <= 0) return this;
            Map<String, Object> element = new LinkedHashMap<>();
            element.put("type", "spacer");
            element.put("height", height);
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
        public String title = "";
        /** 0 = 由内容自适应；宿主只在屏幕范围内尊重脚本给出的值。 */
        public int width = 0;
        public int height = 0;
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
    }

    private static final ConcurrentHashMap<String, String> sessionByKind = new ConcurrentHashMap<>();
    private static final AtomicLong nextSession = new AtomicLong();

    private UiBridge() {
    }

    /**
     * 向宿主开窗：脚本提供完整 {@link Document}。
     * 宿主只渲染原语并回报 shown / closed；按钮动作与内容语义由脚本自行
     * {@link Util#takeUiReply(String)} 消费。失败抛 {@link ShowFailedException}。
     */
    public static Handle show(String kind, Document document) {
        String key = kindKey(kind);
        String session;
        try {
            session = openSession(kind);
        } catch (ShowFailedException e) {
            SpiderDebug.log("UiBridge openSession: " + e.getMessage());
            Util.notify("弹窗关闭确认超时，请重试");
            throw e;
        }
        Document doc = document == null ? new Document() : document;
        try {
            showDocument(session, doc);
        } catch (ShowFailedException e) {
            SpiderDebug.log("UiBridge showDocument: " + e.getMessage());
            sessionByKind.remove(key, session);
            closeDocument(session);
            Util.waitUiAction(session, "closed", Util.UI_CLOSE_WAIT_MS);
            Util.notify("弹窗未能显示，请重试");
            throw e;
        }
        return handleFor(key, session);
    }

    /**
     * 脚本主动关窗并等宿主 closed。成功返回 true。
     * toast 等由脚本自行 {@link Util#notify}。
     */
    public static boolean close(String kind) {
        String key = kindKey(kind);
        String session = currentSession(kind);
        if (session.isEmpty()) return true;
        sessionByKind.remove(key, session);
        closeDocument(session);
        boolean ok = Util.waitUiAction(session, "closed", Util.UI_CLOSE_WAIT_MS);
        Util.clearHostClientInfo(session);
        Util.clearPendingUiNotify();
        return ok;
    }


    /**
     * 当前 kind 弹窗对应的客户端平台（android/ios/…）。
     * 以 Flutter 前端为准；按 session 隔离。须在 show/shown 握手成功后读取。
     */
    public static String hostPlatform(String kind) {
        return Util.hostPlatform(currentSession(kind));
    }

    public static boolean hostDesktop(String kind) {
        return Util.hostDesktop(currentSession(kind));
    }

    public static void dispose(Handle handle) {
        if (handle == null) return;
        try {
            handle.dispose();
        } catch (Throwable ignored) {
        }
    }

    /** 脚本用的内部 kind；跨宿主边界只有不透明 session id。按 Scope 隔离。 */
    public static String currentSession(String kind) {
        return sessionByKind.getOrDefault(kindKey(kind), "");
    }

    private static String openSession(String kind) {
        String key = kindKey(kind);
        String session = "ui-" + Long.toUnsignedString(nextSession.incrementAndGet(), 36)
                + "-" + Long.toUnsignedString(System.nanoTime(), 36);
        String previous = sessionByKind.put(key, session);
        if (previous != null && !previous.equals(session)) {
            closeDocument(previous);
            if (!Util.waitUiAction(previous, "closed", Util.UI_CLOSE_WAIT_MS)) {
                sessionByKind.remove(key, session);
                throw new ShowFailedException("wait closed timeout for " + previous);
            }
            Util.clearHostClientInfo(previous);
        }
        return session;
    }

    private static void showDocument(String session, Document doc) {
        Map<String, Object> document = new LinkedHashMap<>();
        document.put("id", session);
        document.put("title", doc.title == null ? "" : doc.title);
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
        // 宽高由脚本传入；≤0 表示不强制，宿主按图片固有尺寸。
        if (width > 0) element.put("width", width);
        if (height > 0) element.put("height", height);
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

    private static Map<String, Object> action(String id, String label, boolean dismiss) {
        Map<String, Object> action = new LinkedHashMap<>();
        action.put("id", id);
        action.put("label", label);
        action.put("dismiss", dismiss);
        return action;
    }

    private static Handle handleFor(String kind, String session) {
        return () -> {
            sessionByKind.remove(kind, session);
            closeDocument(session);
            Util.waitUiAction(session, "closed", Util.UI_CLOSE_WAIT_MS);
            Util.clearHostClientInfo(session);
            Util.clearPendingUiNotify();
        };
    }

    private static String normalizeKind(String kind) {
        if (kind == null || kind.trim().isEmpty()) return "ui";
        return kind.trim().toLowerCase();
    }

    /** kind 按 Scope（优先 userId）隔离；已带分隔符的 key 不再二次前缀。 */
    private static String kindKey(String kind) {
        String k = normalizeKind(kind);
        if (k.indexOf('\u0001') >= 0) return k;
        String scope = Util.scopeId();
        if (scope == null || scope.isEmpty()) return k;
        return scope + '\u0001' + k;
    }

}
