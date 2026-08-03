package com.github.catvod.utils;

import com.github.catvod.Init;
import com.github.catvod.Proxy;
import com.github.catvod.crawler.SpiderDebug;
import com.github.catvod.net.OkHttp;
import com.github.catvod.net.OkResult;
import cn.hutool.core.util.URLUtil;
import okhttp3.MediaType;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;
import org.apache.commons.lang3.StringUtils;

import java.io.IOException;
import java.math.BigInteger;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.Collection;
import java.util.Date;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicLong;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class Util {
    /** 当前 JAR 调用所属的 Flutter clientId / Scope（由 SpiderBridge 从请求注入）。 */
    private static final ThreadLocal<String> CLIENT_ID_TL = new ThreadLocal<>();
    /** 远端鉴权用户；有则 postMsg 优先按 userId 路由到该用户设备。 */
    private static final ThreadLocal<String> USER_ID_TL = new ThreadLocal<>();

    private static final AtomicLong UI_NOTIFY_EPOCH = new AtomicLong();
    private static final ExecutorService UI_MESSAGES = Executors.newSingleThreadExecutor(r -> {
        Thread thread = new Thread(r, "catvod-ui-messages");
        thread.setDaemon(true);
        return thread;
    });
    public static final String patternAli = "(https:\\/\\/www\\.aliyundrive\\.com\\/s\\/[^\"]+|https:\\/\\/www\\.alipan\\.com\\/s\\/[^\"]+)";
    public static final String patternQuark = "(https:\\/\\/pan\\.quark\\.cn\\/s\\/[^\"]+)";
    public static final String patternUC = "(https:\\/\\/drive\\.uc\\.cn\\/s\\/[^\"]+)";
    public static final Pattern RULE = Pattern.compile("http((?!http).){12,}?\\.(m3u8|mp4|flv|avi|mkv|rm|wmv|mpg|m4a|mp3)\\?.*|http((?!http).){12,}\\.(m3u8|mp4|flv|avi|mkv|rm|wmv|mpg|m4a|mp3)|http((?!http).)*?video/tos*");
    public static final String CHROME = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/117.0.0.0 Safari/537.36";
    public static final String SAFARI = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.33";
    public static final String ACCEPT = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7";
    public static final List<String> MEDIA = Arrays.asList("mp4", "mkv", "wmv", "flv", "avi", "iso", "mpg", "ts", "mp3", "aac", "flac", "m4a", "ape", "ogg");
    public static final List<String> SUB = Arrays.asList("srt", "ass", "ssa", "vtt");

    private static HashMap<String, String> webHttpHeaderMap;

    public static final String CLIENT_ID = "76917ccccd4441c39457a04f6084fb2f";

    public static boolean isVip(String url) {
        List<String> hosts = Arrays.asList("iqiyi.com", "v.qq.com", "youku.com", "le.com", "tudou.com", "mgtv.com", "sohu.com", "acfun.cn", "bilibili.com", "baofeng.com", "pptv.com");
        for (String host : hosts) if (url.contains(host)) return true;
        return false;
    }

    public static boolean isBlackVodUrl(String url) {
        List<String> hosts = Arrays.asList("973973.xyz", ".fit:");
        for (String host : hosts) if (url.contains(host)) return true;
        return false;
    }

    public static boolean isVideoFormat(String url) {
        if (url.contains("url=http") || url.contains(".js") || url.contains(".css") || url.contains(".html"))
            return false;
        return RULE.matcher(url).find();
    }

    public static String findByRegex(String regex, String content, Integer groupCount) {
        // 创建 Pattern 对象
        Pattern r = Pattern.compile(regex);

        // 现在创建 matcher 对象
        Matcher m = r.matcher(content);
        if (m.find()) {
            return m.group(groupCount);
        } else {
            return "";
        }
    }

    public static byte[] toUtf8(byte[] bytes) {
        return new String(bytes, StandardCharsets.UTF_8).getBytes();
    }

    public static boolean isSub(String ext) {
        return SUB.contains(ext);
    }

    public static boolean isMedia(String text) {
        return MEDIA.contains(getExt(text));
    }

    public static String getExt(String name) {
        return name.contains(".") ? name.substring(name.lastIndexOf(".") + 1) : name;
    }

    public static String getSize(double size) {
        if (size <= 0) return "";
        if (size > 1024 * 1024 * 1024 * 1024.0) {
            size /= (1024 * 1024 * 1024 * 1024.0);
            return String.format(Locale.getDefault(), "%.2f%s", size, "TB");
        } else if (size > 1024 * 1024 * 1024.0) {
            size /= (1024 * 1024 * 1024.0);
            return String.format(Locale.getDefault(), "%.2f%s", size, "GB");
        } else if (size > 1024 * 1024.0) {
            size /= (1024 * 1024.0);
            return String.format(Locale.getDefault(), "%.2f%s", size, "MB");
        } else {
            size /= 1024.0;
            return String.format(Locale.getDefault(), "%.2f%s", size, "KB");
        }
    }

    //todo
    public static String fixUrl(String base, String src) {
        if (src.startsWith("//")) {
            URI parse = URI.create(base);
            return parse.getScheme() + ":" + src;
        } else if (!src.contains("://")) {
            URI parse = URI.create(base);
            return parse.getScheme() + "://" + parse.getHost() + src;
        } else {
            return src;
        }
    }

    public static String removeExt(String text) {
        return text.contains(".") ? text.substring(0, text.lastIndexOf(".")) : text;
    }

    public static String substring(String text) {
        return substring(text, 1);
    }

    public static String substring(String text, int num) {
        if (text != null && text.length() > num) {
            return text.substring(0, text.length() - num);
        } else {
            return text;
        }
    }

    public static String getVar(String data, String param) {
        for (String var : data.split("var")) if (var.contains(param)) return checkVar(var);
        return "";
    }

    private static String checkVar(String var) {
        if (var.contains("'")) return var.split("'")[1];
        if (var.contains("\"")) return var.split("\"")[1];
        return "";
    }

    public static String MD5(String src) {
        return MD5(src, "UTF-8");
    }

    public static String MD5(String src, String charset) {
        try {
            MessageDigest md = MessageDigest.getInstance("MD5");
            byte[] messageDigest = md.digest(src.getBytes(charset));
            BigInteger no = new BigInteger(1, messageDigest);
            StringBuilder sb = new StringBuilder(no.toString(16));
            while (sb.length() < 32) sb.insert(0, "0");
            return sb.toString().toLowerCase();
        } catch (Exception e) {
            return "";
        }
    }

    public static byte[] decompressGzip(byte[] compressed) throws IOException {
        try (java.io.ByteArrayInputStream bis = new java.io.ByteArrayInputStream(compressed);
             java.util.zip.GZIPInputStream gis = new java.util.zip.GZIPInputStream(bis)) {
            java.io.ByteArrayOutputStream bos = new java.io.ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n;
            while ((n = gis.read(buf)) >= 0) bos.write(buf, 0, n);
            return bos.toByteArray();
        }
    }

    @FunctionalInterface
    public interface CallBack {
        void apply(String val);
    }

    /** 从响应头提取 cookie（兼容 OkHttp toMultimap 的小写 set-cookie）。 */
    public static String cookiesFrom(OkResult result) {
        if (result == null) return "";
        List<String> cookies = result.getHeader("set-cookie");
        if (cookies == null || cookies.isEmpty()) return "";
        List<String> parts = new ArrayList<>();
        for (String cookie : cookies) {
            if (cookie == null || cookie.isEmpty()) continue;
            parts.add(cookie.split(";", 2)[0]);
        }
        return StringUtils.join(parts, ";");
    }

    /** Handshake timeouts for slow hosts (Win7). */
    public static final long UI_HANDSHAKE_MS = 20_000L;
    public static final long UI_CLOSE_WAIT_MS = 20_000L;

    /** 绑定当前线程的 Flutter clientId（一次 spider 调用期间有效）。 */
    public static void setClientId(String id) {
        if (id == null || id.isEmpty()) CLIENT_ID_TL.remove();
        else CLIENT_ID_TL.set(id);
    }

    public static void clearClientId() {
        CLIENT_ID_TL.remove();
    }

    /** 当前线程绑定的 clientId；无则空串。可能是裸 id，也可能是已带 c:/u: 的 ScopeID。 */
    public static String clientId() {
        String s = CLIENT_ID_TL.get();
        return s == null ? "" : s;
    }

    /** 绑定远端 userId（裸值，不含 u: 前缀）。 */
    public static void setUserId(String id) {
        if (id == null || id.isEmpty()) USER_ID_TL.remove();
        else USER_ID_TL.set(id.trim());
    }

    public static void clearUserId() {
        USER_ID_TL.remove();
    }

    public static String userId() {
        String s = USER_ID_TL.get();
        return s == null ? "" : s;
    }

    /**
     * 会话隔离键：仅远端已登录用 {@code u:<userId>}；本机未登录只用 {@code c:<clientId>}，不造 userId。
     */
    public static String scopeId() {
        String uid = userId();
        if (!uid.isEmpty()) {
            if (uid.startsWith("u:")) return uid;
            if (uid.startsWith("c:")) return uid; // 误写入则原样，勿再套 u:
            return "u:" + uid;
        }
        String cid = clientId();
        if (cid.isEmpty()) return "";
        if (cid.startsWith("u:") || cid.startsWith("c:")) return cid;
        return "c:" + cid;
    }

    public static void clearScope() {
        clearClientId();
        clearUserId();
    }

    /**
     * Notify host via local proxy {@code /postMsg}; also logs.
     * {@code UI:}/{@code UI_CLOSE:} are sent synchronously so waitUiAction can start after delivery.
     * Toasts stay async on the single-thread queue.
     */
    public static void notify(String msg) {
        if (msg == null || msg.isEmpty()) return;
        if (msg.startsWith("UI:") || msg.startsWith("UI_CLOSE:")) {
            notifySync(msg);
            return;
        }
        SpiderDebug.log(msg);
        long epoch = UI_NOTIFY_EPOCH.get();
        // 异步队列在另一线程执行，必须捕获当前 Scope，否则会丢路由。
        final String cid = clientId();
        final String uid = userId();
        UI_MESSAGES.execute(() -> {
            if (epoch != UI_NOTIFY_EPOCH.get()) {
                SpiderDebug.log("postMsg dropped (ui cancelled)");
                return;
            }
            try {
                setClientId(cid);
                setUserId(uid);
                postHttpMsg(msg);
            } catch (Exception e) {
                SpiderDebug.log("postMsg fail: " + e.getMessage());
            } finally {
                clearScope();
            }
        });
    }

    /** Synchronously POST a host message (used for UI handshake). */
    public static void notifySync(String msg) {
        if (msg == null || msg.isEmpty()) return;
        SpiderDebug.log(msg);
        try {
            postHttpMsg(msg);
        } catch (Exception e) {
            SpiderDebug.log("postMsg fail: " + e.getMessage());
        }
    }

    /**
     * Drop queued async toast {@link #notify} payloads.
     * Do not call between sending {@code UI_CLOSE:} and waiting for {@code closed}.
     */
    public static void clearPendingUiNotify() {
        UI_NOTIFY_EPOCH.incrementAndGet();
    }

    /**
     * Non-blocking take of one host UI event JSON/text for an explicit session id.
     * Returns raw body (usually JSON {@code {"action":"...","values":{...}}}).
     */
    public static String takeUiReplyRaw(String session) {
        if (session == null || session.isEmpty()) return "";
        try {
            String base = Proxy.getHostPort();
            if (base == null || base.isEmpty()) return "";
            String url = base + "/uiReply?id=" + urlEncode(session);
            try (Response response = OkHttp.newCall(url).execute()) {
                if (response == null || !response.isSuccessful() || response.body() == null) return "";
                return response.body().string().trim();
            }
        } catch (Exception e) {
            return "";
        }
    }

    /** Parse action field from a raw uiReply body. */
    public static String uiReplyAction(String raw) {
        if (raw == null || raw.isEmpty()) return "";
        String body = raw.trim();
        if (body.startsWith("{")) {
            Map<String, Object> event = Json.parseSafe(body, Map.class);
            if (event == null) return "";
            return String.valueOf(event.getOrDefault("action", "")).trim();
        }
        return body;
    }

    /**
     * 按弹窗 session 记住宿主客户端平台（android/ios/…）。
     * 多前端连同一引擎时不能用全局「最近一次」——会串台。
     */
    private static final java.util.concurrent.ConcurrentHashMap<String, String> hostPlatformBySession =
            new java.util.concurrent.ConcurrentHashMap<>();
    private static final java.util.concurrent.ConcurrentHashMap<String, Boolean> hostDesktopBySession =
            new java.util.concurrent.ConcurrentHashMap<>();

    /** @param session 弹窗 id；空则返回空串（勿再依赖全局最近一次） */
    public static String hostPlatform(String session) {
        if (session == null || session.isEmpty()) return "";
        String p = hostPlatformBySession.get(session);
        return p == null ? "" : p;
    }

    public static boolean hostDesktop(String session) {
        if (session == null || session.isEmpty()) return false;
        return Boolean.TRUE.equals(hostDesktopBySession.get(session));
    }

    /** @deprecated 多前端会串台；请用 {@link #hostPlatform(String session)} 或 {@link UiBridge#hostPlatform(String kind)} */
    @Deprecated
    public static String hostPlatform() {
        return "";
    }

    /** @deprecated 多前端会串台；请用 {@link #hostDesktop(String session)} */
    @Deprecated
    public static boolean hostDesktop() {
        return false;
    }

    @SuppressWarnings("unchecked")
    private static void rememberHostFromReply(String session, String raw) {
        if (session == null || session.isEmpty()) return;
        if (raw == null || raw.isEmpty() || !raw.trim().startsWith("{")) return;
        Map<String, Object> event = Json.parseSafe(raw.trim(), Map.class);
        if (event == null) return;
        Object valuesObj = event.get("values");
        if (!(valuesObj instanceof Map)) return;
        Map<?, ?> values = (Map<?, ?>) valuesObj;
        Object platform = values.get("platform");
        if (platform != null) {
            String p = String.valueOf(platform).trim().toLowerCase(Locale.ROOT);
            if (!p.isEmpty() && !"null".equals(p)) hostPlatformBySession.put(session, p);
        }
        Object desktop = values.get("desktop");
        if (desktop != null) {
            String d = String.valueOf(desktop).trim().toLowerCase(Locale.ROOT);
            hostDesktopBySession.put(session, "true".equals(d) || "1".equals(d) || "yes".equals(d));
        }
    }

    static void clearHostClientInfo(String session) {
        if (session == null || session.isEmpty()) return;
        hostPlatformBySession.remove(session);
        hostDesktopBySession.remove(session);
    }

    /**
     * Block until host reports {@code want} (or a compatible terminal action) for {@code session}.
     * Used for shown/closed handshake; does not dispatch business cancel/submit handlers.
     * When waiting for {@code shown}, caches platform under this {@code session}.
     */
    public static boolean waitUiAction(String session, String want, long timeoutMs) {
        if (session == null || session.isEmpty() || want == null || want.isEmpty()) return false;
        long deadline = System.currentTimeMillis() + Math.max(200L, timeoutMs);
        String expect = want.trim().toLowerCase();
        while (System.currentTimeMillis() < deadline) {
            String raw = takeUiReplyRaw(session);
            String action = uiReplyAction(raw).toLowerCase(Locale.ROOT);
            if (action.isEmpty()) {
                try {
                    Thread.sleep(40);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    return false;
                }
                continue;
            }
            if (action.equals(expect)) {
                if ("shown".equals(expect)) rememberHostFromReply(session, raw);
                if ("closed".equals(expect) || isUiTerminalAction(action)) {
                    // closed 后可清；shown 阶段还要给脚本读 platform，等 clearSession/dispose 再清
                }
                return true;
            }
            if ("shown".equals(expect)) {
                if (isUiTerminalAction(action)) return false;
                continue;
            }
            if ("closed".equals(expect) && isUiTerminalAction(action)) {
                long drainUntil = System.currentTimeMillis() + 300;
                while (System.currentTimeMillis() < drainUntil) {
                    String more = uiReplyAction(takeUiReplyRaw(session)).toLowerCase(Locale.ROOT);
                    if (more.isEmpty() || "closed".equals(more)) break;
                    try {
                        Thread.sleep(20);
                    } catch (InterruptedException e) {
                        Thread.currentThread().interrupt();
                        break;
                    }
                }
                clearHostClientInfo(session);
                return true;
            }
        }
        return false;
    }

    private static boolean isUiTerminalAction(String action) {
        return "closed".equals(action)
                || "dismiss".equals(action)
                || "cancel".equals(action)
                || "timeout".equals(action)
                || "submit".equals(action);
    }

    private static void requeueUiReply(String session, String raw) {
        if (session == null || session.isEmpty() || raw == null || raw.isEmpty()) return;
        try {
            String base = Proxy.getHostPort();
            if (base == null || base.isEmpty()) return;
            RequestBody body = RequestBody.create(raw, MediaType.parse("text/plain; charset=utf-8"));
            Request req = new Request.Builder()
                    .url(base + "/uiReply?id=" + urlEncode(session))
                    .post(body)
                    .build();
            try (Response response = OkHttp.newCall(req).execute()) {
                // ignore
            }
        } catch (Exception ignored) {
        }
    }

    /** Non-blocking read of a host UI event for scripts. No business side effects.
     *  Host returns opaque action ids from the Document; bridge only maps lifecycle
     *  ({@code shown}/{@code closed}/{@code dismiss}/{@code timeout}) and packs
     *  {@code submit} values. Other action ids are returned uppercased as-is. */
    public static String takeUiReply(String kind) {
        if (kind == null || kind.isEmpty()) return "";
        try {
            String session = UiBridge.currentSession(kind);
            if (session.isEmpty()) return "";
            String raw = takeUiReplyRaw(session);
            if (raw.isEmpty()) return "";
            String action;
            Map<String, Object> event = null;
            if (raw.startsWith("{")) {
                event = Json.parseSafe(raw, Map.class);
                if (event == null) return "";
                action = String.valueOf(event.getOrDefault("action", "")).trim();
            } else {
                action = raw.trim();
            }
            if ("shown".equals(action)) {
                requeueUiReply(session, raw);
                return "";
            }
            if ("closed".equals(action)) return "CLOSED";
            if ("dismiss".equals(action) || "timeout".equals(action)) return "CANCEL";
            if ("submit".equals(action)) {
                Object value = null;
                if (event != null) {
                    Object valuesObj = event.get("values");
                    if (valuesObj instanceof Map) {
                        value = ((Map<?, ?>) valuesObj).get("value");
                    }
                }
                return value == null ? "SUBMIT:" : "SUBMIT:" + value;
            }
            if ("cancel".equals(action)) return "CANCEL";
            if (!action.isEmpty()) return action.toUpperCase(Locale.ROOT);
            return "";
        } catch (Exception e) {
            return "";
        }
    }

    private static void postHttpMsg(String msg) throws IOException {
        String base = Proxy.getHostPort();
        if (base == null || base.isEmpty()) return;
        // 远端已登录：userId；本机未登录无 userId，只用 clientId（勿伪造 userId）。
        String uid = userId();
        if (uid.startsWith("u:")) uid = uid.substring(2);
        if (uid.startsWith("c:")) uid = "";
        String cid = clientId();
        String routeQ;
        if (!uid.isEmpty()) {
            routeQ = "userId=" + urlEncode(uid);
        } else if (!cid.isEmpty()) {
            if (cid.startsWith("c:")) {
                routeQ = "clientId=" + urlEncode(cid.substring(2));
            } else if (cid.startsWith("u:")) {
                // 仅当 ThreadLocal 误带了 Scope 时兼容；正常本机不应走这支
                routeQ = "userId=" + urlEncode(cid.substring(2));
            } else {
                routeQ = "clientId=" + urlEncode(cid);
            }
        } else {
            String scope = scopeId();
            routeQ = scope.isEmpty() ? "" : "scopeId=" + urlEncode(scope);
        }
        // Long payloads (e.g. image data-URI) must use POST body; GET query length is limited.
        if (msg.length() > 800) {
            RequestBody body = RequestBody.create(msg, MediaType.parse("text/plain; charset=utf-8"));
            String url = base + "/postMsg" + (routeQ.isEmpty() ? "" : "?" + routeQ);
            Request req = new Request.Builder().url(url).post(body).build();
            try (Response response = OkHttp.newCall(req).execute()) {
                if (response != null && !response.isSuccessful()) {
                    SpiderDebug.log("send msg fail：" + msg.substring(0, Math.min(40, msg.length())));
                }
            }
            return;
        }
        String encoded = urlEncode(msg);
        String url = base + "/postMsg?msg=" + encoded + (routeQ.isEmpty() ? "" : "&" + routeQ);
        try (Response response = OkHttp.newCall(url).execute()) {
            if (response != null && !response.isSuccessful()) {
                SpiderDebug.log("send msg fail：" + msg);
            }
        }
    }

    public static void notify(String msg, Integer timeMills) {
        notify(msg);
    }

    public static void showToast(String msg, Integer timeMills) {
        notify(msg == null ? "" : msg);
    }

    public static String getDigit(String text) {
        try {
            String newText = text;
            Matcher matcher = Pattern.compile(".*(1080|720|2160|4k|4K).*").matcher(text);
            if (matcher.find()) newText = matcher.group(1) + " " + text;
            matcher = Pattern.compile("^([0-9]+)").matcher(text);
            if (matcher.find()) newText = matcher.group(1) + " " + newText;
            return newText.replaceAll("\\D+", "") + " " + newText.replaceAll("\\d+", "");
        } catch (Exception e) {
            return "";
        }
    }

    public static String getMimeType(String contentDisposition) {
        if (contentDisposition.endsWith(".mp4")) {
            return "video/mp4";
        } else if (contentDisposition.endsWith(".webm")) {
            return "video/webm";
        } else if (contentDisposition.endsWith(".avi")) {
            return "video/x-msvideo";
        } else if (contentDisposition.endsWith(".wmv")) {
            return "video/x-ms-wmv";
        } else if (contentDisposition.endsWith(".flv")) {
            return "video/x-flv";
        } else if (contentDisposition.endsWith(".mov")) {
            return "video/quicktime";
        } else if (contentDisposition.endsWith(".mkv")) {
            return "video/x-matroska";
        } else if (contentDisposition.endsWith(".mpeg")) {
            return "video/mpeg";
        } else if (contentDisposition.endsWith(".3gp")) {
            return "video/3gpp";
        } else if (contentDisposition.endsWith(".ts")) {
            return "video/MP2T";
        } else if (contentDisposition.endsWith(".mp3")) {
            return "audio/mp3";
        } else if (contentDisposition.endsWith(".wav")) {
            return "audio/wav";
        } else if (contentDisposition.endsWith(".aac")) {
            return "audio/aac";
        } else {
            return null;
        }
    }

    public static void sleep(Integer time) {
        try {
            Thread.sleep(time);
        } catch (InterruptedException e) {
//            throw new RuntimeException(e);
        }
    }

    /**
     * @param referer
     * @param cookie  多个cookie name=value;name2=value2
     * @return
     */
    public static HashMap<String, String> webHeaders(String referer, String cookie) {
        return webHeaders(referer, "", cookie);
    }

    public static HashMap<String, String> webHeaders(String referer) {
        return webHeaders(referer, "");
    }

    public static HashMap<String, String> webHeaders(String referer, String url, String cookie) {
        webHttpHeaderMap = new HashMap<>();
//                    webHttpHeaderMap.put(HttpHeaders.CONTENT_TYPE, ContentType.Application.INSTANCE.getJson().getContentType());
        webHttpHeaderMap.put("Accept-Language", "zh-CN,zh;q=0.8,zh-TW;q=0.7,zh-HK;q=0.5,en-US;q=0.3,en;q=0.2");
        webHttpHeaderMap.put("Connection", "keep-alive");
        webHttpHeaderMap.put("User-Agent", CHROME);
        webHttpHeaderMap.put("Accept", "*/*");
//        webHttpHeaderMap.put("Accept"_ENCODING, "br, deflate, gzip, x-gzip");
        if (StringUtils.isNotBlank(referer)) {
            webHttpHeaderMap.put("Referer", referer);
        }
        if (StringUtils.isNotBlank(url)) {
            URI host = URLUtil.getHost(URLUtil.url(url));
            webHttpHeaderMap.put("Host", host.getHost());
        }
        if (StringUtils.isNotBlank(cookie)) {
            webHttpHeaderMap.put("Cookie", cookie);
        }

//        webHttpHeaderMap.put(io.ktor.http.HttpHeaders.INSTANCE.getOrigin(), u);
        return webHttpHeaderMap;
    }

    public static String timestampToDateStr(Long timestamp) {
        return new SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss z", Locale.US).format(new Date(timestamp));
    }

    public static String base64Encode(String str) {
        if (str == null) return "";
        return new String(Base64.getEncoder().encode(str.getBytes()));
    }


    public static String base64Encode(byte[] str) {
        return new String(Base64.getEncoder().encode(str));
    }

    public static String base64Decode(String str) {
        if (StringUtils.isBlank(str)) return "";
        try {
            return new String(Base64.getDecoder().decode(str));
        } catch (IllegalArgumentException e) {
            // 配置偶发把明文 URL/JSON 当 Base64；避免整站 init 直接崩溃。
            return "";
        }
    }

    public static String stringJoin(String separate, Collection<String> list) {
        return StringUtils.join(list, separate);
    }

    public static String stringJoin(Collection<String> list, String separate) {
        return StringUtils.join(list, separate);
    }

    /**
     * 字符串相似度匹配
     *
     * @returns
     */

    public static LCSResult lcs(String str1, String str2) {
        if (str1 == null || str2 == null) {
            return new LCSResult(0, "", 0);
        }

        StringBuilder sequence = new StringBuilder();
        int str1Length = str1.length();
        int str2Length = str2.length();
        int[][] num = new int[str1Length][str2Length];
        int maxlen = 0;
        int lastSubsBegin = 0;

        for (int i = 0; i < str1Length; i++) {
            for (int j = 0; j < str2Length; j++) {
                if (str1.charAt(i) != str2.charAt(j)) {
                    num[i][j] = 0;
                } else {
                    if (i == 0 || j == 0) {
                        num[i][j] = 1;
                    } else {
                        num[i][j] = 1 + num[i - 1][j - 1];
                    }

                    if (num[i][j] > maxlen) {
                        maxlen = num[i][j];
                        int thisSubsBegin = i - num[i][j] + 1;
                        if (lastSubsBegin == thisSubsBegin) {
                            // if the current LCS is the same as the last time this block ran
                            sequence.append(str1.charAt(i));
                        } else {
                            // this block resets the string builder if a different LCS is found
                            lastSubsBegin = thisSubsBegin;
                            sequence.setLength(0); // clear it
                            sequence.append(str1.substring(lastSubsBegin, i + 1));
                        }
                    }
                }
            }
        }
        return new LCSResult(maxlen, sequence.toString(), lastSubsBegin);
    }

    public static class LCSResult {
        public int length;
        public String sequence;
        public int offset;

        public LCSResult(int length, String sequence, int offset) {
            this.length = length;
            this.sequence = sequence;
            this.offset = offset;
        }
    }

    public static Integer findAllIndexes(List<String> arr, String value) {

        for (int i = 0; i < arr.size(); i++) {
            if (arr.get(i).equals(value)) {
                return i;
            }
        }
        return 0;
    }


    public static final Pattern THUNDER = Pattern.compile("(magnet|thunder|ed2k):.*");

    public static boolean isThunder(String url) {
        return THUNDER.matcher(url).find() || isTorrent(url);
    }

    public static boolean isTorrent(String url) {
        return !url.startsWith("magnet") && url.endsWith(".torrent");
    }

    public static void copy(String text) {
        try {
            android.content.ClipboardManager manager = (android.content.ClipboardManager) Init.context().getSystemService(android.content.Context.CLIPBOARD_SERVICE);
            manager.setPrimaryClip(android.content.ClipData.newPlainText("fongmi", text));
            notify("已复制");
        } catch (Exception e) {
            e.printStackTrace();
        }
    }

    // --- host / TV ABI (bridge 原有，站点瘦包后父优先落到这里) ---

    public static final String OKHTTP = "okhttp/" + okhttp3.OkHttp.VERSION;
    public static final int URL_SAFE = android.util.Base64.DEFAULT | android.util.Base64.URL_SAFE | android.util.Base64.NO_WRAP;

    public static String base64(String s) {
        return base64(s.getBytes(StandardCharsets.UTF_8));
    }

    public static String base64(byte[] bytes) {
        return base64(bytes, android.util.Base64.DEFAULT | android.util.Base64.NO_WRAP);
    }

    public static String base64(String s, int flags) {
        return base64(s.getBytes(StandardCharsets.UTF_8), flags);
    }

    public static String base64(byte[] bytes, int flags) {
        return android.util.Base64.encodeToString(bytes, flags);
    }

    public static byte[] decode(String s) {
        return decode(s, android.util.Base64.DEFAULT | android.util.Base64.NO_WRAP);
    }

    public static byte[] decode(String s, int flags) {
        return android.util.Base64.decode(s, flags);
    }

    public static byte[] hex2byte(String s) {
        byte[] bytes = new byte[s.length() / 2];
        for (int i = 0; i < bytes.length; i++) {
            bytes[i] = Integer.valueOf(s.substring(i * 2, i * 2 + 2), 16).byteValue();
        }
        return bytes;
    }

    public static boolean equals(String name, String md5) {
        return md5(Path.jar(name)).equalsIgnoreCase(md5);
    }

    public static String md5(String src) {
        return MD5(src);
    }

    public static String md5(java.io.File file) {
        try {
            MessageDigest digest = MessageDigest.getInstance("MD5");
            try (java.io.FileInputStream fis = new java.io.FileInputStream(file)) {
                byte[] bytes = new byte[16384];
                int count;
                while ((count = fis.read(bytes)) != -1) digest.update(bytes, 0, count);
            }
            StringBuilder sb = new StringBuilder();
            for (byte b : digest.digest()) sb.append(Integer.toString((b & 0xff) + 0x100, 16).substring(1));
            return sb.toString();
        } catch (Exception e) {
            return "";
        }
    }

    public static boolean containOrMatch(String text, String regex) {
        try {
            return text.contains(regex) || text.matches(regex);
        } catch (Exception e) {
            return false;
        }
    }

    public static String getIp() {
        try {
            String ip = getHostAddress("wlan");
            if (!ip.isEmpty()) return ip;
            ip = getHostAddress("eth");
            if (!ip.isEmpty()) return ip;
            return getHostAddress("");
        } catch (Exception e) {
            return "";
        }
    }

    private static String getHostAddress(String keyword) throws java.net.SocketException {
        for (java.util.Enumeration<java.net.NetworkInterface> en = java.net.NetworkInterface.getNetworkInterfaces(); en.hasMoreElements(); ) {
            java.net.NetworkInterface nif = en.nextElement();
            if (!keyword.isEmpty() && !nif.getName().startsWith(keyword)) continue;
            for (java.util.Enumeration<java.net.InetAddress> addresses = nif.getInetAddresses(); addresses.hasMoreElements(); ) {
                java.net.InetAddress addr = addresses.nextElement();
                if (!addr.isLoopbackAddress() && addr instanceof java.net.Inet4Address) {
                    return addr.getHostAddress();
                }
            }
        }
        return "";
    }

    private static String urlEncode(String s) {
        try {
            return java.net.URLEncoder.encode(s == null ? "" : s, "UTF-8");
        } catch (Exception e) {
            return s == null ? "" : s;
        }
    }
}
