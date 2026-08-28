package com.bobo.kotv.bridge;

import android.app.Activity;
import android.app.Application;
import android.content.Context;
import com.bobo.kotv.host.UiContext;
import com.github.catvod.Init;
import com.github.catvod.crawler.Spider;
import com.github.catvod.crawler.SpiderNull;
import com.google.gson.Gson;
import com.google.gson.JsonObject;

import fi.iki.elonen.NanoHTTPD;

import java.io.*;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

/**
 * CatVod JAR 爬虫桥接程序。
 * 默认：stdin 读一次 JSON，stdout 写一次结果。
 * --serve：常驻进程，连续读写多个 JSON（JVM 只启动一次）。
 * 构建: ./bridge/build.sh
 */
public class SpiderBridge {
    private static final Gson GSON = new Gson();
    /** 桌面用 stub Application；Android 须先 [setAndroidContext]。 */
    private static volatile Context CONTEXT;
    private static final Map<String, Spider> spiders = new ConcurrentHashMap<>();
    private static final Map<String, ClassLoader> loaders = new ConcurrentHashMap<>();
    private static final Map<String, Method> proxyMethods = new ConcurrentHashMap<>();
    private static volatile String recentJar;

    static {
        if (!isArtVm()) {
            CONTEXT = new Application();
        }
    }

    /** Android Native：注入真实 Application Context（宿主已编进 App CL）。 */
    public static void setAndroidContext(Context ctx) {
        if (ctx == null) return;
        Context app = ctx.getApplicationContext();
        CONTEXT = app != null ? app : ctx;
        if (CONTEXT instanceof Application) {
            UiContext.setApplication((Application) CONTEXT);
        }
        if (ctx instanceof Activity) {
            UiContext.setActivity((Activity) ctx);
        }
        // Android 不允许/不完整支持名为 BC 的 BouncyCastle Provider；
        // hutool DigestUtil/AES 默认走 BC 会抛 NoSuchAlgorithmException。
        disableHutoolBouncyCastle();
    }

    /** Android：注入当前前台 Activity，供 TV dex jar 内 AlertDialog 拿 window token。 */
    public static void setAndroidActivity(Activity activity) {
        UiContext.setActivity(activity);
    }

    private static void disableHutoolBouncyCastle() {
        try {
            Class<?> g = Class.forName("cn.hutool.crypto.GlobalBouncyCastleProvider");
            g.getMethod("setUseBouncyCastle", boolean.class).invoke(null, false);
        } catch (Throwable ignored) {
        }
    }

    private static Context ctx() {
        Context c = CONTEXT;
        if (c != null) return c;
        if (isArtVm()) {
            throw new IllegalStateException("SpiderBridge.setAndroidContext() required on Android");
        }
        c = new Application();
        CONTEXT = c;
        return c;
    }

    private static boolean isArtVm() {
        try {
            Class.forName("dalvik.system.DexClassLoader");
            return true;
        } catch (Throwable ignored) {
            return false;
        }
    }

    public static void main(String[] args) throws Exception {
        disableSystemProxies();
        for (String arg : args) {
            if ("--self-check".equals(arg)) {
                System.out.println(selfCheck());
                return;
            }
        }
        boolean serveHttp = false;
        boolean serveStdio = false;
        int httpPort = 0;
        for (int i = 0; i < args.length; i++) {
            String arg = args[i];
            if ("--serve".equals(arg)) {
                serveHttp = true;
            } else if ("--serve-stdio".equals(arg)) {
                serveStdio = true;
            } else if (arg.startsWith("--http-port=")) {
                httpPort = Integer.parseInt(arg.substring("--http-port=".length()).trim());
                serveHttp = true;
            } else if ("--http-port".equals(arg) && i + 1 < args.length) {
                httpPort = Integer.parseInt(args[++i].trim());
                serveHttp = true;
            }
        }
        String propPort = System.getProperty("kotv.bridge.port", "").trim();
        if (!propPort.isEmpty()) {
            try {
                httpPort = Integer.parseInt(propPort);
                serveHttp = true;
            } catch (NumberFormatException ignored) {
            }
        }
        if (serveStdio) {
            serveStdio();
            return;
        }
        if (serveHttp) {
            if (httpPort <= 0) {
                httpPort = 9979;
            }
            serveHttp(httpPort);
            return;
        }
        String input = new String(System.in.readAllBytes(), StandardCharsets.UTF_8);
        System.out.print(call(input));
    }

    /**
     * HTTP 常驻：Go 多客户端可并发 POST /jar/call。
     * 仍保留 --serve-stdio 供调试。
     */
    private static void serveHttp(int port) throws IOException {
        NanoHTTPD httpd = new NanoHTTPD("127.0.0.1", port) {
            @Override
            public Response serve(IHTTPSession session) {
                try {
                    String uri = session.getUri() == null ? "/" : session.getUri();
                    NanoHTTPD.Method method = session.getMethod();
                    if (NanoHTTPD.Method.GET.equals(method) && ("/health".equals(uri) || "/".equals(uri))) {
                        return newFixedLengthResponse(NanoHTTPD.Response.Status.OK, "application/json; charset=utf-8",
                                "{\"ok\":true,\"mode\":\"http\"}");
                    }
                    if (!NanoHTTPD.Method.POST.equals(method)) {
                        return newFixedLengthResponse(NanoHTTPD.Response.Status.METHOD_NOT_ALLOWED, "text/plain", "POST required");
                    }
                    String body = readHttpBody(session);
                    if ("/jar/call".equals(uri)) {
                        if (body == null || body.isEmpty()) {
                            return newFixedLengthResponse(NanoHTTPD.Response.Status.BAD_REQUEST, "text/plain", "empty body");
                        }
                        String out = call(body);
                        return newFixedLengthResponse(NanoHTTPD.Response.Status.OK, "application/json; charset=utf-8", out);
                    }
                    if ("/jar/cancel".equals(uri)) {
                        applyCancel(body);
                        return newFixedLengthResponse(NanoHTTPD.Response.Status.OK, "application/json; charset=utf-8", "{\"ok\":true}");
                    }
                    if ("/jar/interrupt".equals(uri)) {
                        clear();
                        try {
                            com.github.catvod.net.OkHttp.cancelAll();
                        } catch (Throwable ignored) {
                        }
                        return newFixedLengthResponse(NanoHTTPD.Response.Status.OK, "application/json; charset=utf-8", "{\"ok\":true}");
                    }
                    return newFixedLengthResponse(NanoHTTPD.Response.Status.NOT_FOUND, "text/plain", "not found");
                } catch (Throwable t) {
                    JsonObject err = new JsonObject();
                    err.addProperty("error", t.toString());
                    return newFixedLengthResponse(NanoHTTPD.Response.Status.INTERNAL_ERROR, "application/json; charset=utf-8",
                            GSON.toJson(err));
                }
            }
        };
        httpd.start(NanoHTTPD.SOCKET_READ_TIMEOUT, false);
        // Go 侧解析此行等待就绪；勿写 stdout（避免污染其它协议）。
        System.err.println("KOTV_BRIDGE_HTTP=127.0.0.1:" + port);
        System.err.flush();
        Object lock = new Object();
        synchronized (lock) {
            try {
                lock.wait();
            } catch (InterruptedException ignored) {
            }
        }
    }

    private static void applyCancel(String body) {
        String cid = "";
        if (body != null && !body.isEmpty()) {
            try {
                JsonObject o = GSON.fromJson(body, JsonObject.class);
                if (o != null && o.has("clientId") && !o.get("clientId").isJsonNull()) {
                    cid = o.get("clientId").getAsString();
                    if (cid == null) cid = "";
                }
            } catch (Throwable ignored) {
            }
        }
        try {
            if (cid.isEmpty()) {
                com.github.catvod.net.OkHttp.cancelAll();
            } else {
                com.github.catvod.net.OkHttp.cancel(cid);
            }
        } catch (Throwable ignored) {
        }
    }

    private static String readHttpBody(NanoHTTPD.IHTTPSession session) {
        Map<String, String> files = new HashMap<>();
        try {
            session.parseBody(files);
        } catch (Throwable ignored) {
        }
        String fromMap = files.get("postData");
        if (fromMap == null || fromMap.isEmpty()) {
            fromMap = files.get("data");
        }
        if (fromMap != null && !fromMap.trim().isEmpty()) {
            return fromMap.trim();
        }
        String lenHdr = session.getHeaders() != null ? session.getHeaders().get("content-length") : null;
        int len = 0;
        try {
            if (lenHdr != null) len = Integer.parseInt(lenHdr.trim());
        } catch (NumberFormatException ignored) {
        }
        if (len <= 0 || len > 2 * 1024 * 1024) return "";
        try {
            byte[] buf = new byte[len];
            int off = 0;
            InputStream in = session.getInputStream();
            while (off < len) {
                int n = in.read(buf, off, len - off);
                if (n < 0) break;
                off += n;
            }
            return new String(buf, 0, off, StandardCharsets.UTF_8).trim();
        } catch (Throwable ignored) {
            return "";
        }
    }

    /** 旧版行协议：每行一个 JSON 请求/响应（串行，仅调试）。 */
    private static void serveStdio() throws IOException {
        BufferedReader in = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
        String line;
        while ((line = in.readLine()) != null) {
            line = line.trim();
            if (line.isEmpty()) {
                continue;
            }
            byte[] out = (call(line) + "\n").getBytes(StandardCharsets.UTF_8);
            System.out.write(out);
            System.out.flush();
        }
    }

    public static String call(String input) {
        disableSystemProxies();
        if (isArtVm()) {
            Activity act = UiContext.activity();
            if (act != null) {
                UiContext.setActivity(act);
            }
        }
        String clientId = "";
        String userId = "";
        boolean remoteUi = false;
        try {
            JsonObject req = GSON.fromJson(input, JsonObject.class);
            if (req.has("clientId") && !req.get("clientId").isJsonNull()) {
                clientId = req.get("clientId").getAsString();
                if (clientId == null) clientId = "";
            }
            if (req.has("userId") && !req.get("userId").isJsonNull()) {
                userId = req.get("userId").getAsString();
                if (userId == null) userId = "";
            }
            // clientId 可能已是 ScopeID（u:/c:）；从中拆出 userId。
            if (userId.isEmpty() && clientId.startsWith("u:") && clientId.length() > 2) {
                userId = clientId.substring(2);
            }
            if (!clientId.isEmpty()) {
                com.github.catvod.utils.Util.setClientId(clientId);
            }
            if (!userId.isEmpty()) {
                com.github.catvod.utils.Util.setUserId(userId);
            }
            if (req.has("remoteUi") && !req.get("remoteUi").isJsonNull()) {
                try {
                    remoteUi = req.get("remoteUi").getAsBoolean();
                } catch (Throwable ignored) {
                }
            }
            if (remoteUi) {
                com.github.catvod.utils.Util.enterRemoteUi(clientId, userId);
            } else {
                com.github.catvod.utils.Util.clearRemoteUi();
            }
            String method = req.get("method").getAsString();
            if ("selfCheck".equals(method)) {
                return selfCheck();
            }
            JsonObject argsObj = req.has("args") && !req.get("args").isJsonNull()
                    ? req.getAsJsonObject("args") : new JsonObject();
            if ("proxyGlobal".equals(method)) {
                Map<String, String> params = GSON.fromJson(argsObj.get("params"), Map.class);
                return encodeProxyResponse(invokeJarProxy(params));
            }
            if ("clear".equals(method)) {
                clear();
                return "{}";
            }
            // 打断卡住的 OkHttp 调用（换源/关停时）。
            if ("cancelAll".equals(method)) {
                try {
                    com.github.catvod.net.OkHttp.cancelAll();
                } catch (Throwable ignored) {
                }
                return "{}";
            }
            // 按 Flutter clientId 软取消 OkHttp（多前端并发时不杀 JVM）。
            if ("cancelClient".equals(method)) {
                String cid = "";
                if (argsObj.has("clientId") && !argsObj.get("clientId").isJsonNull()) {
                    cid = argsObj.get("clientId").getAsString();
                } else if (req.has("clientId") && !req.get("clientId").isJsonNull()) {
                    cid = req.get("clientId").getAsString();
                }
                if (cid == null) cid = "";
                try {
                    if (cid.isEmpty()) {
                        com.github.catvod.net.OkHttp.cancelAll();
                    } else {
                        com.github.catvod.net.OkHttp.cancel(cid);
                    }
                } catch (Throwable ignored) {
                }
                return "{}";
            }
            if ("setRecent".equals(method)) {
                String jar = "";
                if (argsObj.has("jar") && !argsObj.get("jar").isJsonNull()) {
                    jar = argsObj.get("jar").getAsString();
                } else if (req.has("jar") && !req.get("jar").isJsonNull()) {
                    jar = req.get("jar").getAsString();
                }
                if (jar != null && !jar.isEmpty()) {
                    // BaseLoader.parseJar(jar, true)：加载后再设 recent。
                    parseJar(jar);
                    recentJar = jar;
                }
                return "{}";
            }
            // JarLoader.parseJar / dex：只确保 ClassLoader+Init+Proxy，不改 recent。
            if ("parseJar".equals(method)) {
                String jar = "";
                if (argsObj.has("jar") && !argsObj.get("jar").isJsonNull()) {
                    jar = argsObj.get("jar").getAsString();
                } else if (req.has("jar") && !req.get("jar").isJsonNull()) {
                    jar = req.get("jar").getAsString();
                }
                if (jar != null && !jar.isEmpty()) {
                    parseJar(jar);
                    if (argsObj.has("recent") && argsObj.get("recent").getAsBoolean()) {
                        recentJar = jar;
                    }
                }
                return "{}";
            }
            // 缓存刷新后按路径重载：丢弃该 jar 的爬虫/ClassLoader 再重新 parseJar，
            // 否则磁盘换了新包、内存里仍是旧类（TV 靠整包 clear 达成同样效果）。
            if ("reloadJar".equals(method)) {
                String jar = "";
                if (argsObj.has("jar") && !argsObj.get("jar").isJsonNull()) {
                    jar = argsObj.get("jar").getAsString();
                } else if (req.has("jar") && !req.get("jar").isJsonNull()) {
                    jar = req.get("jar").getAsString();
                }
                if (jar != null && !jar.isEmpty()) {
                    unloadJar(jar);
                    parseJar(jar);
                }
                return "{}";
            }
            if ("configNet".equals(method)) {
                applyNetConfig(argsObj);
                return "{}";
            }
            if ("configProxy".equals(method)) {
                setUserProxy(argsObj.has("url") && !argsObj.get("url").isJsonNull()
                        ? argsObj.get("url").getAsString() : "");
                return "{}";
            }
            // JarLoader.jsonExt / jsonExtMix：只用 recent ClassLoader，不走 getSpider。
            if ("jsonExt".equals(method)) {
                String parseKey = argsObj.get("parseKey").getAsString();
                LinkedHashMap<String, String> jxs = GSON.fromJson(argsObj.get("jxs"), LinkedHashMap.class);
                String url = argsObj.get("url").getAsString();
                return emptyToObject(invokeJsonExt(parseKey, jxs, url));
            }
            if ("jsonExtMix".equals(method)) {
                String parseKey = argsObj.get("parseKey").getAsString();
                String name = argsObj.get("name").getAsString();
                String flag = argsObj.get("flag").getAsString();
                LinkedHashMap<String, HashMap<String, String>> jxs =
                        GSON.fromJson(argsObj.get("jxs"), LinkedHashMap.class);
                String url = argsObj.get("url").getAsString();
                return emptyToObject(invokeJsonExtMix(parseKey, name, flag, jxs, url));
            }
            // JsLoader.createFun：从 jar ClassLoader 调 pdfh/pdfa/pd/pdfl（Go QJS 经 RPC）。
            if ("jsParse".equals(method)) {
                return invokeJsParse(argsObj);
            }
            String key = req.get("key").getAsString();
            String api = req.get("api").getAsString();
            String ext = req.has("ext") ? req.get("ext").getAsString() : "";
            String jar = req.get("jar").getAsString();
            String spiderMethod = method;
            try {
                Spider spider = getSpider(key, api, ext, jar);
                // recent 只由 parseJar(recent=true)/setRecent/Site.recent 更新，
                // 不在每次 spider 方法调用时覆盖（避免并行多 jar 时 Mix/Json 抖 recent）。
                return nonempty(invoke(spider, spiderMethod, argsObj, jar));
            } catch (Throwable t) {
                t.printStackTrace(System.err);
                // 对齐 TV SiteViewModel：内容接口失败回空结果，不把 Java 异常弹到首页。
                if (isSoftFailContentMethod(spiderMethod)) {
                    return "{}";
                }
                JsonObject err = new JsonObject();
                err.addProperty("error", t.toString());
                return GSON.toJson(err);
            }
        } catch (Throwable t) {
            t.printStackTrace(System.err);
            JsonObject err = new JsonObject();
            err.addProperty("error", t.toString());
            return GSON.toJson(err);
        } finally {
            if (remoteUi) {
                com.github.catvod.utils.Util.leaveRemoteUi();
            }
            com.github.catvod.utils.Util.clearScope();
        }
    }

    /** home/category/search 等：失败时 TV 发 Result.empty()，不展示堆栈。 */
    private static boolean isSoftFailContentMethod(String method) {
        if (method == null) return false;
        switch (method) {
            case "homeContent":
            case "homeVideoContent":
            case "categoryContent":
            case "detailContent":
            case "searchContent":
            case "liveContent":
                return true;
            default:
                return false;
        }
    }

    /** JarLoader 把空串当成加载失败（HTTP 500）；所有出口至少回 JSON。 */
    private static String nonempty(String raw) {
        if (raw == null || raw.trim().isEmpty()) {
            return "{}";
        }
        return raw;
    }

 /** 避免继承系统 SOCKS/HTTP 代理导致 NoRouteToHost。 */
 /** 用户在 KOTV 设置里配置的全局代理；随设置变更由 configProxy 命令更新，供 OkProxySelector 回落使用。 */
    private static volatile java.net.Proxy userProxy;
    private static volatile boolean systemProxyInstalled;

    private static void disableSystemProxies() {
        System.setProperty("java.net.useSystemProxies", "false");
        for (String k : new String[]{
                "socksProxyHost", "socksProxyPort",
                "http.proxyHost", "http.proxyPort",
                "https.proxyHost", "https.proxyPort",
                "ftp.proxyHost", "ftp.proxyPort",
                "http.nonProxyHosts"
        }) {
            System.clearProperty(k);
            System.setProperty(k, "");
        }
 // 只安装一次默认选择器，OkProxySelector 构造时捕获它并读取 userProxy 动态字段。
        if (systemProxyInstalled) return;
        systemProxyInstalled = true;
        java.net.ProxySelector.setDefault(new java.net.ProxySelector() {
            @Override
            public List<java.net.Proxy> select(java.net.URI uri) {
                java.net.Proxy p = userProxy;
                if (p != null && uri != null && uri.getHost() != null
                        && !"127.0.0.1".equals(uri.getHost()) && !"localhost".equals(uri.getHost())) {
                    return Collections.singletonList(p);
                }
                return Collections.singletonList(java.net.Proxy.NO_PROXY);
            }

            @Override
            public void connectFailed(java.net.URI uri, java.net.SocketAddress sa, IOException ioe) {
            }
        });
    }

 /** 用户代理设置：JAR 未命中配置 proxy 规则时走用户代理。 */
    private static void setUserProxy(String spec) {
        spec = spec == null ? "" : spec.trim();
        if (spec.isEmpty()) {
            userProxy = null;
            return;
        }
        try {
            java.net.Proxy.Type type = java.net.Proxy.Type.HTTP;
            if (spec.startsWith("socks")) type = java.net.Proxy.Type.SOCKS;
            String hostPort = spec.contains("://") ? spec.substring(spec.indexOf("://") + 3) : spec;
            int slash = hostPort.indexOf('/');
            if (slash >= 0) hostPort = hostPort.substring(0, slash);
            String host = hostPort;
            int port = type == java.net.Proxy.Type.SOCKS ? 1080 : 8080;
            int colon = hostPort.lastIndexOf(':');
            if (colon >= 0) {
                host = hostPort.substring(0, colon);
                port = Integer.parseInt(hostPort.substring(colon + 1));
            }
            userProxy = new java.net.Proxy(type, new java.net.InetSocketAddress(host, port));
        } catch (Throwable e) {
            System.err.println("setUserProxy failed: " + e);
            userProxy = null;
        }
    }

    private static Spider getSpider(String key, String api, String ext, String jarPath) throws Exception {
        // spKey = md5(jar) + siteKey；JarLoader.getSpider。
        String spKey = md5Hex(jarPath) + key;
        Spider cached = spiders.get(spKey);
        if (cached != null && !(cached instanceof SpiderNull)) {
            ClassLoader existing = loaders.get(jarPath);
            refreshSpiderJarUi(existing);
            return cached;
        }
        // 勿永久缓存 SpiderNull：Android 上首次因 Writable dex 失败后会一直空响应。
        try {
            parseJar(jarPath);
            ClassLoader loader = loaders.get(jarPath);
            if (loader == null) {
                throw new IllegalStateException("No jar loaded: " + jarPath);
            }
            refreshSpiderJarUi(loader);
            String className = spiderClassName(api);
            ClassLoader prev = Thread.currentThread().getContextClassLoader();
            Thread.currentThread().setContextClassLoader(loader);
            try {
                Class<?> clazz;
                try {
                    clazz = loader.loadClass(className);
                } catch (ClassNotFoundException e) {
                    String shortName = className;
                    int dot = shortName.lastIndexOf('.');
                    if (dot >= 0) shortName = shortName.substring(dot + 1);
                    System.err.println("getSpider missing " + className + " in " + jarPath
                            + "; spiders=" + listSiteSpiders(jarPath));
                    throw new ClassNotFoundException(
                            "当前爬虫包没有 " + shortName + "（配置 api=" + api + "）",
                            e);
                }
                Constructor<?> ctor = clazz.getDeclaredConstructor();
                ctor.setAccessible(true);
                Object instance = ctor.newInstance();
                if (!(instance instanceof Spider)) {
                    throw new IllegalStateException(
                            className + " is " + instance.getClass().getName() + ", not Spider");
                }
                Spider spider = (Spider) instance;
                spider.siteKey = key;
                initializeSpider(spider, ext);
                spiders.put(spKey, spider);
                return spider;
            } finally {
                Thread.currentThread().setContextClassLoader(prev);
            }
        } catch (Exception e) {
            System.err.println(
                    "getSpider failed key=" + key + " api=" + api + " jar=" + jarPath + ": " + e);
            e.printStackTrace(System.err);
            // 对齐 TV JarLoader.getSpider：加载失败（含 jar 缺该 csp 类）静默降级为
            // SpiderNull，站点显示空列表而不是把异常弹到首页。
            SpiderNull nullSpider = new SpiderNull();
            nullSpider.siteKey = key;
            return nullSpider;
        }
    }

    /** {@code csp_Nostr} → {@code com.github.catvod.spider.Nostr}，与 TV {@code api.split("csp_")[1]} 一致。 */
    private static String spiderClassName(String api) {
        String name = api == null ? "" : api.trim();
        String[] parts = name.split("csp_");
        if (parts.length > 1 && !parts[1].isEmpty()) {
            return "com.github.catvod.spider." + parts[1];
        }
        if (name.startsWith("csp_")) {
            name = name.substring(4);
        }
        return "com.github.catvod.spider." + name;
    }

    private static String listSiteSpiders(String jarPath) {
        Method m = siteJarListMethod;
        if (m == null) return "?";
        try {
            Object v = m.invoke(null, jarPath);
            return v == null ? "?" : String.valueOf(v);
        } catch (Throwable t) {
            return "list-failed:" + t.getMessage();
        }
    }

    /**
     * JarLoader.parseJar：同一 jar 只加载一次，创建 ClassLoader 并调用 Init / 注册 Proxy。
     * 桌面用 URLClassLoader 代替 DexClassLoader。
     */
    private static void parseJar(String jarPath) {
        if (jarPath == null || jarPath.isEmpty()) return;
        if (loaders.containsKey(jarPath)) return;
        synchronized (SpiderBridge.class) {
            if (loaders.containsKey(jarPath)) return;
            try {
                ClassLoader loader = createLoader(jarPath);
                ClassLoader prev = Thread.currentThread().getContextClassLoader();
                try {
                    Thread.currentThread().setContextClassLoader(loader);
                    initializeHost();
                    initializeSpiderJar(jarPath, loader);
                } finally {
                    Thread.currentThread().setContextClassLoader(prev);
                }
                loaders.put(jarPath, loader);
            } catch (Exception e) {
                // 对齐 TV JarLoader.load：加载失败静默记日志；getSpider 侧因 loader 缺失
                // 落到 SpiderNull（空列表），不把异常弹到界面。
                System.err.println("parseJar failed: " + jarPath + ": " + e);
                e.printStackTrace(System.err);
            }
        }
    }

    private static void initializeHost() {
        Init.set(ctx());
        com.github.catvod.Proxy.set(configuredProxyPort());
    }

    private static int configuredProxyPort() {
 String value = System.getProperty("kotv.proxy.port", System.getenv("KOTV_PROXY_PORT"));
        try {
            return Integer.parseInt(value);
        } catch (Exception ignored) {
            return 9978;
        }
    }

    /**
     * JarLoader.getSpider：
     * {@code spider.init(App.get(), ext)} → {@link Spider#init(Context, String)}。
     * 官方蜘蛛均 override 该方法读取 extend；基类默认只转发 {@link Spider#init(Context)}。
     */
    private static void initializeSpider(Spider spider, String extend) throws Exception {
        if (extend == null) {
            extend = "";
        }
        Context initCtx = ctx();
        spider.init(initCtx, extend);
    }

    private static String md5Hex(String s) {
        try {
            java.security.MessageDigest md = java.security.MessageDigest.getInstance("MD5");
            byte[] dig = md.digest(s.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder(dig.length * 2);
            for (byte b : dig) {
                sb.append(String.format("%02x", b));
            }
            return sb.toString();
        } catch (Exception e) {
            return Integer.toHexString(s.hashCode());
        }
    }

    /**
     * Desktop site ClassLoader（URLClassLoader，父 = bridge CL）。
     * PC JVM 瘦包按 FongMi `pc/` 的 exclude + verifyUniversalJar 打包；运行时 Util/OkHttp 等由 bridge 提供。
     * TV dex jar 不走此路径（Android 见 {@link #createDexLoader}）。
     */
    private static final class SpiderClassLoader extends URLClassLoader {
        SpiderClassLoader(URL[] urls, ClassLoader parent) {
            super(urls, parent);
        }
    }

    private static ClassLoader createLoader(String jarPath) throws Exception {
        File file = new File(jarPath);
        // Android ART：站点 jar 已是 dex，必须用 DexClassLoader（无 URLClassLoader）。
        if (isArtVm()) {
            return createDexLoader(file);
        }
        return new SpiderClassLoader(
                new URL[]{file.toURI().toURL()},
                SpiderBridge.class.getClassLoader()
        );
    }

    /** App 侧注入：JarDexer.ensureSiteDexJar（Method 句柄，无需按类型名查找） */
    private static volatile Method siteJarEnsureMethod;
    private static volatile Method siteJarCreateLoaderMethod;
    private static volatile Method siteJarListMethod;

    /** Android：JarLoader 注入 ensure 方法句柄。 */
    public static void setSiteJarEnsureMethod(Method method) {
        siteJarEnsureMethod = method;
    }

    public static void setSiteJarCreateLoaderMethod(Method method) {
        siteJarCreateLoaderMethod = method;
    }

    public static void setSiteJarListMethod(Method method) {
        siteJarListMethod = method;
    }

    private static ClassLoader createDexLoader(File jarFile) throws Exception {
        if (!jarFile.isFile() || jarFile.length() == 0L) {
            throw new IOException("site jar missing: " + jarFile);
        }
        Context c = ctx();
        // 对齐 TV：parent = App.get().getClassLoader()。宿主 Spider 必须在 App CL。
        ClassLoader parent = c != null ? c.getClassLoader() : SpiderBridge.class.getClassLoader();
        if (parent == null) {
            parent = SpiderBridge.class.getClassLoader();
        }
        Method create = siteJarCreateLoaderMethod;
        if (create != null) {
            try {
                Object cl = create.invoke(null, c, jarFile.getAbsolutePath(), parent);
                if (cl instanceof ClassLoader) {
                    return (ClassLoader) cl;
                }
            } catch (java.lang.reflect.InvocationTargetException e) {
                Throwable cauze = e.getCause() != null ? e.getCause() : e;
                throw new IOException("createSiteClassLoader failed: " + cauze.getMessage(), cauze);
            }
        }
        File sealed = resolveSealedSiteJar(c, jarFile);
        File opt;
        try {
            java.lang.reflect.Method getCodeCache = c.getClass().getMethod("getCodeCacheDir");
            Object dir = getCodeCache.invoke(c);
            opt = new File(String.valueOf(dir), "kotv_site_dex");
        } catch (Throwable t) {
            opt = new File(System.getProperty("java.io.tmpdir"), "kotv_site_dex");
        }
        if (!opt.isDirectory() && !opt.mkdirs()) {
            throw new IOException("cannot create dex opt dir: " + opt);
        }
        Class<?> dcl = Class.forName("dalvik.system.DexClassLoader");
        return (ClassLoader) dcl.getConstructor(String.class, String.class, String.class, ClassLoader.class)
                .newInstance(sealed.getAbsolutePath(), opt.getAbsolutePath(), opt.getAbsolutePath(), parent);
    }

    /**
     * 站点 jar = PC/安卓通用 JVM .class 包。Android 经 App 注入的 Method 调 JarDexer 转 dex。
     * 不在此按 Context.class / 类型名反射查找（bridge shim Context ≠ 真机 Context）。
     */
    private static File resolveSealedSiteJar(Context c, File jarFile) throws Exception {
        Method ensure = siteJarEnsureMethod;
        if (ensure == null) {
            throw new IOException(
                    "site jar ensure not registered (JarLoader must call setSiteJarEnsureMethod). jar="
                            + jarFile.getName());
        }
        try {
            Object path = ensure.invoke(null, c, jarFile.getAbsolutePath());
            if (path != null) {
                File sealed = new File(path.toString());
                if (sealed.isFile() && sealed.length() > 0L) {
                    return sealed;
                }
            }
        } catch (java.lang.reflect.InvocationTargetException e) {
            Throwable cauze = e.getCause() != null ? e.getCause() : e;
            throw new IOException("JarDexer failed: " + cauze.getMessage(), cauze);
        }
        throw new IOException("JarDexer returned empty for " + jarFile.getName());
    }

    /** Android 上社区 wrapper Init 可能卡在 WebView 配置页；超时后继续注册 Proxy。 */
    private static final long SPIDER_INIT_TIMEOUT_MS = 20_000L;

    /**
     * CatVod spider jars may expose a shared Init hook. It is optional:
     * older jars do not have it and Android-dependent variants can reject the
     * desktop Context shim, so loading an individual spider must still work.
     */
    private static void invokeSpiderJarInit(ClassLoader loader) {
        if (isArtVm()) {
            invokeSpiderJarInitTimed(loader, SPIDER_INIT_TIMEOUT_MS);
            return;
        }
        invokeSpiderJarInit0(loader);
    }

    private static void invokeSpiderJarInitTimed(ClassLoader loader, long timeoutMs) {
        ExecutorService exec = Executors.newSingleThreadExecutor(r -> {
            Thread t = new Thread(r, "kotv-spider-init");
            t.setDaemon(true);
            return t;
        });
        Future<?> future = exec.submit(() -> invokeSpiderJarInit0(loader));
        try {
            future.get(timeoutMs, TimeUnit.MILLISECONDS);
        } catch (TimeoutException e) {
            future.cancel(true);
            System.err.println("spider Init timed out after " + timeoutMs
                    + "ms (WebView/config page?), continuing without full Init");
        } catch (Exception e) {
            System.err.println("optional spider Init skipped: " + e);
        } finally {
            exec.shutdownNow();
        }
    }

    private static void invokeSpiderJarInit0(ClassLoader loader) {
        try {
            Class<?> clz = loader.loadClass("com.github.catvod.spider.Init");
            Method init = clz.getMethod("init", Context.class);
            Context app = ctx();
            boolean initialized = false;
            // 对齐 TV JarLoader.invokeInit：只传 Application，不传 Activity、不 inject Activity。
            // 社区 jar 拿到 Activity 会在主线程立刻 new WebView 弹配置页，WebView 不可用时会 FATAL。
            if (app != null) {
                try {
                    Context asApp = app.getApplicationContext();
                    init.invoke(null, asApp != null ? asApp : app);
                    initialized = true;
                } catch (java.lang.reflect.InvocationTargetException ite) {
                    Throwable cause = ite.getCause() != null ? ite.getCause() : ite;
                    if (!(cause instanceof ClassCastException)) {
                        throw ite;
                    }
                }
            }
            if (!initialized && !isArtVm()) {
                Activity act = UiContext.activity();
                if (act != null) {
                    try {
                        init.invoke(null, act);
                    } catch (java.lang.reflect.InvocationTargetException ite) {
                        Throwable cause = ite.getCause() != null ? ite.getCause() : ite;
                        if (!(cause instanceof ClassCastException)) {
                            throw ite;
                        }
                    }
                }
            }
        } catch (ClassNotFoundException ignored) {
            // Init is not part of the original spider ABI.
        } catch (Throwable error) {
            System.err.println("optional spider Init skipped: " + error);
        }
    }

    /** 仅 remoteUi 远端弹窗时补 Activity；Init 阶段不注入，避免 jar 过早建 WebView。 */
    private static void injectJarInitActivity(Class<?> initClz, Activity act) {
        if (act == null || initClz == null) {
            return;
        }
        for (String name : new String[]{"setActivity", "bindActivity", "attachActivity"}) {
            try {
                initClz.getMethod(name, Activity.class).invoke(null, act);
                return;
            } catch (Throwable ignored) {
            }
        }
        try {
            java.lang.reflect.Field field = initClz.getDeclaredField("activity");
            field.setAccessible(true);
            if (Activity.class.isAssignableFrom(field.getType())) {
                field.set(null, act);
                return;
            }
        } catch (Throwable ignored) {
        }
        for (java.lang.reflect.Field field : initClz.getDeclaredFields()) {
            try {
                if (!java.lang.ref.WeakReference.class.isAssignableFrom(field.getType())) {
                    continue;
                }
                field.setAccessible(true);
                Object current = field.get(null);
                if (current instanceof java.lang.ref.WeakReference) {
                    java.lang.ref.WeakReference<?> ref = (java.lang.ref.WeakReference<?>) current;
                    Object target = ref.get();
                    if (target == null || target instanceof Activity) {
                        field.set(null, new java.lang.ref.WeakReference<>(act));
                        return;
                    }
                }
            } catch (Throwable ignored) {
            }
        }
    }

    private static void refreshSpiderJarUi(ClassLoader loader) {
        if (!isArtVm() || loader == null || !com.github.catvod.utils.Util.hasRemoteUi()) {
            return;
        }
        try {
            Class<?> clz = loader.loadClass("com.github.catvod.spider.Init");
            injectJarInitActivity(clz, UiContext.activity());
        } catch (Throwable ignored) {
        }
    }

    private static void initializeSpiderJar(String jarPath, ClassLoader loader) {
        invokeSpiderJarInit(loader);
        try {
            Class<?> proxy = loader.loadClass("com.github.catvod.spider.Proxy");
            proxyMethods.put(jarPath, proxy.getMethod("proxy", Map.class));
        } catch (ClassNotFoundException ignored) {
        } catch (Throwable error) {
            System.err.println("optional spider Proxy skipped: " + error);
        }
    }

    private static String selfCheck() {
        JsonObject out = new JsonObject();
        try {
            Class.forName("okhttp3.OkHttpClient");
            String okhttpVersion = okhttpVersion();
            if (!okhttpVersion.startsWith("5.")) {
                throw new IllegalStateException("expected OkHttp 5.x, got " + okhttpVersion);
            }
            out.addProperty("okhttp", okhttpVersion);
            out.addProperty("brotli", Class.forName("org.brotli.dec.BrotliInputStream").getName());
            out.addProperty("smbj", Class.forName("com.hierynomus.smbj.SMBClient").getName());
            out.addProperty("sardineAndroid",
                    Class.forName("com.thegrizzlylabs.sardineandroid.Sardine").getName());
            out.addProperty("sardine", Class.forName("com.github.sardine.Sardine").getName());
            out.addProperty("simpleXml", Class.forName("org.simpleframework.xml.strategy.Strategy").getName());
            out.addProperty("ok", true);
        } catch (Throwable error) {
            out.addProperty("ok", false);
            out.addProperty("error", error.toString());
        }
        return GSON.toJson(out);
    }

    private static String okhttpVersion() throws Exception {
        try {
            Class<?> okhttp = Class.forName("okhttp3.OkHttp");
            return String.valueOf(okhttp.getField("VERSION").get(null));
        } catch (ReflectiveOperationException ignored) {
            try (InputStream version = SpiderBridge.class.getResourceAsStream("/kotv-okhttp-version.txt")) {
                return version == null ? "" : new String(version.readAllBytes(), StandardCharsets.UTF_8).trim();
            }
        }
    }

    private static Object invokeJarProxy(Map<String, String> params) {
        String recent = recentJar;
        if (recent != null) {
            Object result = invokeProxyMethod(proxyMethods.get(recent), params);
            if (result != null) return result;
        }
        for (Map.Entry<String, Method> entry : proxyMethods.entrySet()) {
            if (entry.getKey().equals(recent)) continue;
            Object result = invokeProxyMethod(entry.getValue(), params);
            if (result != null) return result;
        }
        return null;
    }

 /** 将 KOTV 点播配置的 headers/proxy/hosts 灌入 bridge OkHttp（按 clientId 隔离）。 */
    private static void applyNetConfig(JsonObject args) {
        try {
            String cid = "";
            if (args.has("clientId") && !args.get("clientId").isJsonNull()) {
                cid = args.get("clientId").getAsString();
                if (cid == null) cid = "";
            }
            if (cid.isEmpty()) {
                cid = com.github.catvod.utils.Util.clientId();
            }
            List<com.github.catvod.bean.Header> headers = java.util.Collections.emptyList();
            List<com.github.catvod.bean.Proxy> proxies = java.util.Collections.emptyList();
            List<String> hosts = java.util.Collections.emptyList();
            com.github.catvod.bean.Doh doh = null;
            if (args.has("headers") && !args.get("headers").isJsonNull()) {
                headers = com.github.catvod.bean.Header.arrayFrom(args.get("headers"));
            }
            if (args.has("proxy") && !args.get("proxy").isJsonNull()) {
                proxies = com.github.catvod.bean.Proxy.arrayFrom(args.get("proxy"));
            }
            if (args.has("hosts") && !args.get("hosts").isJsonNull()) {
                hosts = jsonToStringList(args.get("hosts"));
            }
            if (args.has("doh") && !args.get("doh").isJsonNull()) {
                List<com.github.catvod.bean.Doh> list = com.github.catvod.bean.Doh.arrayFrom(args.get("doh"));
                if (!list.isEmpty()) doh = list.get(0);
            }
            java.util.Map<String, String> hostMap = new java.util.HashMap<>();
            for (String host : hosts) {
                if (host == null) continue;
                String[] splits = host.split("=", 2);
                if (splits.length == 2) hostMap.put(splits[0].trim(), splits[1].trim());
            }
            com.github.catvod.net.NetProfiles.replace(cid, headers, proxies, hostMap, doh);
            // 同步刷新 OkDns DoH 缓存键（replace 已写入 Profile）。
            if (doh != null) {
                com.github.catvod.net.OkHttp.dns().putDoh(cid, doh);
            } else {
                com.github.catvod.net.OkHttp.dns().putDoh(cid, null);
            }
        } catch (Throwable e) {
            System.err.println("configNet failed: " + e);
        }
    }

    private static List<String> jsonToStringList(com.google.gson.JsonElement element) {
        List<String> result = new ArrayList<>();
        if (element == null || element.isJsonNull()) return result;
        if (element.isJsonArray()) {
            for (com.google.gson.JsonElement item : element.getAsJsonArray()) {
                if (!item.isJsonNull()) result.add(item.getAsString());
            }
        }
        return result;
    }

    private static void clear() {
        for (Spider spider : spiders.values()) {
            try {
                spider.destroy();
            } catch (Throwable error) {
                System.err.println("spider destroy failed: " + error);
            }
        }
        spiders.clear();
        proxyMethods.clear();
        recentJar = null;
        for (ClassLoader loader : loaders.values()) {
            if (loader instanceof URLClassLoader) {
                try {
                    ((URLClassLoader) loader).close();
                } catch (IOException ignored) {
                }
            }
        }
        loaders.clear();
    }

    /** 按路径卸载单个 jar：destroy 其爬虫、关闭 loader 并移除缓存，供磁盘包刷新后重载。 */
    private static void unloadJar(String jarPath) {
        if (jarPath == null || jarPath.isEmpty()) return;
        // spKey = md5(jar) + siteKey，见 getSpider。
        String prefix = md5Hex(jarPath);
        for (java.util.Iterator<Map.Entry<String, Spider>> it = spiders.entrySet().iterator(); it.hasNext();) {
            Map.Entry<String, Spider> entry = it.next();
            if (!entry.getKey().startsWith(prefix)) continue;
            try {
                entry.getValue().destroy();
            } catch (Throwable error) {
                System.err.println("spider destroy failed: " + error);
            }
            it.remove();
        }
        ClassLoader loader = loaders.remove(jarPath);
        if (loader instanceof URLClassLoader) {
            try {
                ((URLClassLoader) loader).close();
            } catch (IOException ignored) {
            }
        }
        proxyMethods.remove(jarPath);
        // recentJar 只是路径：重载后同路径新 loader 仍是「最近」，保留给 jsonExt 用。
    }

    private static Object invokeProxyMethod(Method method, Map<String, String> params) {
        if (method == null) return null;
        try {
            return method.invoke(null, params);
        } catch (Throwable error) {
            Throwable cause = error;
            if (error instanceof java.lang.reflect.InvocationTargetException
                    && ((java.lang.reflect.InvocationTargetException) error).getCause() != null) {
                cause = ((java.lang.reflect.InvocationTargetException) error).getCause();
            }
            System.err.println("jar proxy failed: " + cause);
            cause.printStackTrace(System.err);
            return null;
        }
    }

    @SuppressWarnings("unchecked")
    private static String encodeProxyResponse(Object raw) throws Exception {
        if (raw == null) {
            JsonObject err = new JsonObject();
            err.addProperty("error", "Invalid proxy response");
            return GSON.toJson(err);
        }
        Object normalized = normalizeProxyPayload(raw);
        if (normalized instanceof NanoHTTPD.Response) {
            return encodeNanoResponse((NanoHTTPD.Response) normalized);
        }
        if (normalized instanceof okhttp3.Response) {
            return encodeOkHttpResponse((okhttp3.Response) normalized);
        }
        if (normalized instanceof Object[]) {
            Object[] array = (Object[]) normalized;
            if (array.length < 3) {
                JsonObject err = new JsonObject();
                err.addProperty("error", "Invalid proxy response");
                return GSON.toJson(err);
            }
            int status = array[0] instanceof Number ? ((Number) array[0]).intValue() : 200;
            String contentType = array[1] != null ? String.valueOf(array[1]) : "";
            Object body = array[2];
            Map<?, ?> headers = array.length > 3 && array[3] instanceof Map ? (Map<?, ?>) array[3] : null;
            return proxyJson(status, contentType, body, headers);
        }
        return proxyJson(200, "text/plain; charset=utf-8", normalized, null);
    }

    /**
     * 兼容多种 spider 代理返回：
     * 1) [status, contentType, body, headers?]
     * 2) [NanoHTTPD.Response]（MultiThread 多线程下载）
     * 3) [okhttp3.Response]
     * 4) [[status, contentType, body, headers?]]
     */
    private static Object normalizeProxyPayload(Object raw) {
        if (raw == null) return null;
        if (raw instanceof NanoHTTPD.Response || raw instanceof okhttp3.Response) return raw;
        if (!(raw instanceof Object[])) return raw;
        Object[] array = (Object[]) raw;
        if (array.length == 0) return raw;
        if (array.length == 1) {
            Object only = array[0];
            if (only instanceof NanoHTTPD.Response || only instanceof okhttp3.Response || only instanceof Object[]) {
                return normalizeProxyPayload(only);
            }
        }
        return raw;
    }

    private static String encodeNanoResponse(NanoHTTPD.Response response) throws Exception {
        try (NanoHTTPD.Response resp = response) {
            int status = resp.getStatus().getRequestStatus();
            String type = resp.getMimeType() != null ? resp.getMimeType() : "";
            Map<String, String> headers = nanoResponseHeaders(resp);
            InputStream data = resp.getData();
            if (data == null) {
                return proxyJson(status, type, new byte[0], headers);
            }
            return proxyJson(status, type, data, headers);
        }
    }

    @SuppressWarnings("unchecked")
    private static Map<String, String> nanoResponseHeaders(NanoHTTPD.Response response) {
        try {
            Field field = NanoHTTPD.Response.class.getDeclaredField("header");
            field.setAccessible(true);
            Map<String, String> map = (Map<String, String>) field.get(response);
            return map == null ? new LinkedHashMap<>() : new LinkedHashMap<>(map);
        } catch (ReflectiveOperationException ignored) {
            return new LinkedHashMap<>();
        }
    }

    private static String encodeOkHttpResponse(okhttp3.Response response) throws Exception {
        try (okhttp3.Response resp = response) {
            Map<String, String> headers = new LinkedHashMap<>();
            for (String name : resp.headers().names()) headers.put(name, resp.header(name, ""));
            String type = resp.body() != null && resp.body().contentType() != null
                    ? resp.body().contentType().toString() : resp.header("Content-Type", "");
            if (resp.body() == null) {
                return proxyJson(resp.code(), type, new byte[0], headers);
            }
            return proxyJson(resp.code(), type, resp.body().byteStream(), headers);
        }
    }

 // 大于此阈值的响应体溢写到临时文件，避免把巨量 base64 塞进单行 JSON（爆管道/堆内存）。
    private static final int PROXY_SPILL_THRESHOLD = 1024 * 1024;

    private static String proxyJson(int status, String contentType, Object body, Map<?, ?> headers) throws IOException {
        JsonObject out = new JsonObject();
        out.addProperty("status", status);
        out.addProperty("contentType", contentType == null ? "" : contentType);
        if (body instanceof InputStream) {
            // 真流式：本机 TCP 泵给 Go，避免整段原画溢写磁盘（远端 PC→安卓 so/go 多线程必用）。
            out.addProperty("bodyStream", startBodyStream((InputStream) body));
        } else {
            byte[] bytes;
            if (body instanceof byte[]) {
                bytes = (byte[]) body;
            } else if (body == null) {
                bytes = new byte[0];
            } else {
                bytes = String.valueOf(body).getBytes(StandardCharsets.UTF_8);
            }
            if (bytes.length > PROXY_SPILL_THRESHOLD) {
                out.addProperty("bodyFile", spillBytes(bytes).getAbsolutePath());
            } else {
                out.addProperty("bodyBase64", Base64.getEncoder().encodeToString(bytes));
                out.addProperty("body", new String(bytes, StandardCharsets.UTF_8));
            }
        }
        if (headers != null) out.add("headers", GSON.toJsonTree(headers));
        return GSON.toJson(out);
    }

    /**
     * 在 127.0.0.1 上开一次性 TCP：Go 拨号后边读边写客户端。
     * 返回 "127.0.0.1:port"。
     */
    private static String startBodyStream(InputStream in) throws IOException {
        final ServerSocket ss = new ServerSocket();
        ss.setReuseAddress(true);
        ss.bind(new InetSocketAddress("127.0.0.1", 0), 1);
        ss.setSoTimeout(120_000);
        final int port = ss.getLocalPort();
        Thread t = new Thread(() -> {
            Socket client = null;
            try {
                client = ss.accept();
                try {
                    ss.close();
                } catch (IOException ignored) {
                }
                OutputStream out = client.getOutputStream();
                byte[] buf = new byte[64 * 1024];
                int n;
                while ((n = in.read(buf)) != -1) {
                    out.write(buf, 0, n);
                }
                out.flush();
            } catch (Throwable e) {
                System.err.println("kotv proxy bodyStream failed: " + e);
            } finally {
                try {
                    in.close();
                } catch (IOException ignored) {
                }
                if (client != null) {
                    try {
                        client.close();
                    } catch (IOException ignored) {
                    }
                }
                try {
                    ss.close();
                } catch (IOException ignored) {
                }
            }
        }, "kotv-proxy-body-stream");
        t.setDaemon(true);
        t.start();
        return "127.0.0.1:" + port;
    }

    private static File proxySpillDir() {
        File dir = new File(ctx().getCacheDir(), "proxy");
        dir.mkdirs();
        return dir;
    }

    private static File spillStream(InputStream is) throws IOException {
        File file = File.createTempFile("proxy-", ".bin", proxySpillDir());
        try (InputStream in = is; OutputStream out = new FileOutputStream(file)) {
            byte[] buf = new byte[64 * 1024];
            int n;
            while ((n = in.read(buf)) != -1) out.write(buf, 0, n);
        }
        return file;
    }

    private static File spillBytes(byte[] bytes) throws IOException {
        File file = File.createTempFile("proxy-", ".bin", proxySpillDir());
        try (OutputStream out = new FileOutputStream(file)) {
            out.write(bytes);
        }
        return file;
    }

    @SuppressWarnings("unchecked")
    private static String invoke(Spider spider, String method, JsonObject args, String jar) throws Exception {
        switch (method) {
            case "init":
                // getSpider 已 init；不再二次 init。
                return "{}";
            case "homeContent":
                return emptyToObject(spider.homeContent(args.has("filter") && args.get("filter").getAsBoolean()));
            case "homeVideoContent":
                return emptyToObject(spider.homeVideoContent());
            case "categoryContent": {
                HashMap<String, String> extend = new HashMap<>();
                if (args.has("extend")) {
                    extend = GSON.fromJson(args.get("extend"), HashMap.class);
                }
                return emptyToObject(spider.categoryContent(
                        args.get("tid").getAsString(),
                        args.get("pg").getAsString(),
                        args.has("filter") && args.get("filter").getAsBoolean(),
                        extend
                ));
            }
            case "detailContent": {
                List<String> ids = GSON.fromJson(args.get("ids"), List.class);
                return emptyToObject(spider.detailContent(ids));
            }
            case "searchContent":
                return emptyToObject(spider.searchContent(
                        args.get("key").getAsString(),
                        args.has("quick") && args.get("quick").getAsBoolean(),
                        args.has("pg") ? args.get("pg").getAsString() : "1"
                ));
            case "playerContent": {
                List<String> vip = args.has("vipFlags")
                        ? GSON.fromJson(args.get("vipFlags"), List.class) : null;
                return emptyToObject(spider.playerContent(
                        args.get("flag").getAsString(),
                        args.get("id").getAsString(),
                        vip
                ));
            }
            case "liveContent":
                return emptyToObject(spider.liveContent(args.has("url") ? args.get("url").getAsString() : ""));
            case "action": {
                return emptyToObject(spider.action(args.has("action") ? args.get("action").getAsString() : ""));
            }
            case "manualVideoCheck":
                return Boolean.toString(spider.manualVideoCheck());
            case "isVideoFormat":
                return Boolean.toString(spider.isVideoFormat(args.has("url") ? args.get("url").getAsString() : ""));
            case "proxy": {
 // 有 siteKey 时只走实例 proxy，不回落静态 JAR proxy。
                Map<String, String> params = GSON.fromJson(args.get("params"), Map.class);
                return encodeProxyResponse(spider.proxy(params));
            }
            default:
                return "{}";
        }
    }

    /** 避免 null/空串被 JarLoader 误判为「站点 jar 加载失败」。 */
    private static String emptyToObject(String raw) {
        if (raw == null || raw.trim().isEmpty()) return "{}";
        return raw;
    }

    /** JarLoader.requireRecentLoader：Mix/Json 只从 recent jar 反射。 */
    private static ClassLoader requireRecentLoader() {
        String recent = recentJar;
        if (recent == null || recent.isEmpty()) {
            throw new IllegalStateException("No jar loaded for recent");
        }
        ClassLoader loader = loaders.get(recent);
        if (loader == null) {
            // recent 已设但尚未 parseJar（例如仅 setRecent 旧路径）：补一次真加载。
            parseJar(recent);
            loader = loaders.get(recent);
        }
        if (loader == null) {
            throw new IllegalStateException("No jar loaded for recent key: " + recent);
        }
        return loader;
    }

    /**
     * createFun：用官方 jar 内 {@code com.github.catvod.js.utils.Parser}。
     * Go QuickJS 无法直接 new Java Function(whl.ctx)，故经 bridge RPC；失败由 parser.js 回落。
     */
    @SuppressWarnings("unchecked")
    private static String invokeJsParse(JsonObject args) {
        JsonObject out = new JsonObject();
        try {
            String jar = args.has("jar") && !args.get("jar").isJsonNull()
                    ? args.get("jar").getAsString() : "";
            if (jar != null && !jar.isEmpty()) {
                parseJar(jar);
            }
            ClassLoader loader = (jar != null && !jar.isEmpty() && loaders.containsKey(jar))
                    ? loaders.get(jar) : requireRecentLoader();
            String op = args.has("op") ? args.get("op").getAsString() : "";
            String html = args.has("html") ? args.get("html").getAsString() : "";
            String rule = args.has("rule") ? args.get("rule").getAsString() : "";
            String url = args.has("url") ? args.get("url").getAsString() : "";
            String texts = args.has("texts") ? args.get("texts").getAsString() : "";
            String urls = args.has("urls") ? args.get("urls").getAsString() : "";

            Class<?> parserClz = loader.loadClass("com.github.catvod.js.utils.Parser");
            Object parser = parserClz.getConstructor().newInstance();
            switch (op) {
                case "pdfh": {
                    Object v = parserClz.getMethod("parseDomForUrl", String.class, String.class, String.class)
                            .invoke(parser, html, rule, "");
                    out.addProperty("value", v == null ? "" : String.valueOf(v));
                    return GSON.toJson(out);
                }
                case "pd": {
                    Object v = parserClz.getMethod("parseDomForUrl", String.class, String.class, String.class)
                            .invoke(parser, html, rule, url);
                    out.addProperty("value", v == null ? "" : String.valueOf(v));
                    return GSON.toJson(out);
                }
                case "pdfa": {
                    List<String> list = (List<String>) parserClz
                            .getMethod("parseDomForArray", String.class, String.class)
                            .invoke(parser, html, rule);
                    out.add("list", GSON.toJsonTree(list == null ? List.of() : list));
                    return GSON.toJson(out);
                }
                case "pdfl": {
                    List<String> list = (List<String>) parserClz
                            .getMethod("parseDomForList", String.class, String.class, String.class, String.class, String.class)
                            .invoke(parser, html, rule, texts, urls, url);
                    out.add("list", GSON.toJsonTree(list == null ? List.of() : list));
                    return GSON.toJson(out);
                }
                default:
                    out.addProperty("error", "unknown op: " + op);
                    return GSON.toJson(out);
            }
        } catch (Throwable e) {
            out.addProperty("error", e.toString());
            return GSON.toJson(out);
        }
    }

    private static String invokeJsonExt(String key, LinkedHashMap<String, String> jxs, String url) {
        try {
            Class<?> clz = requireRecentLoader().loadClass("com.github.catvod.parser.Json" + key);
            java.lang.reflect.Method method = clz.getMethod("parse", LinkedHashMap.class, String.class);
            Object result = method.invoke(null, jxs, url);
            return result == null ? "" : result.toString();
        } catch (Exception e) {
            JsonObject err = new JsonObject();
            err.addProperty("error", e.toString());
            return GSON.toJson(err);
        }
    }

    @SuppressWarnings("unchecked")
    private static String invokeJsonExtMix(String key, String name, String flag,
                                          LinkedHashMap<String, HashMap<String, String>> jxs, String url) {
        try {
            Class<?> clz = requireRecentLoader().loadClass("com.github.catvod.parser.Mix" + key);
            java.lang.reflect.Method method = clz.getMethod(
                    "parse", LinkedHashMap.class, String.class, String.class, String.class);
            Object result = method.invoke(null, jxs, name, flag, url);
            return result == null ? "" : result.toString();
        } catch (Exception e) {
            JsonObject err = new JsonObject();
            err.addProperty("error", e.toString());
            return GSON.toJson(err);
        }
    }
}
