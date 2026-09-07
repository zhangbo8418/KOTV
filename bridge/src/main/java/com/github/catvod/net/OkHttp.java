package com.github.catvod.net;

import android.annotation.SuppressLint;

import androidx.collection.ArrayMap;

import com.github.catvod.net.interceptor.AuthInterceptor;
import com.github.catvod.net.interceptor.RequestInterceptor;
import com.github.catvod.net.interceptor.ResponseInterceptor;

import java.security.SecureRandom;
import java.security.cert.X509Certificate;
import java.util.Map;
import java.util.concurrent.TimeUnit;

import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

import okhttp3.Call;
import okhttp3.FormBody;
import okhttp3.Headers;
import okhttp3.HttpUrl;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;
import okhttp3.logging.HttpLoggingInterceptor;

public class OkHttp {

    private static final long TIMEOUT = TimeUnit.SECONDS.toMillis(30);

    private ResponseInterceptor responseInterceptor;
    private RequestInterceptor requestInterceptor;
    private AuthInterceptor authInterceptor;
    private OkAuthenticator authenticator;
    private OkProxySelector selector;
    private OkHttpClient client;
    private OkHttpClient player;
    private OkDns dns;

    public static OkHttp get() {
        return Loader.INSTANCE;
    }

    public static OkDns dns() {
        if (get().dns != null) return get().dns;
        return get().dns = new OkDns();
    }

    public static ResponseInterceptor responseInterceptor() {
        if (get().responseInterceptor != null) return get().responseInterceptor;
        return get().responseInterceptor = new ResponseInterceptor();
    }

    public static RequestInterceptor requestInterceptor() {
        if (get().requestInterceptor != null) return get().requestInterceptor;
        return get().requestInterceptor = new RequestInterceptor();
    }

    public static AuthInterceptor authInterceptor() {
        if (get().authInterceptor != null) return get().authInterceptor;
        return get().authInterceptor = new AuthInterceptor();
    }

    public static OkAuthenticator authenticator() {
        if (get().authenticator != null) return get().authenticator;
        return get().authenticator = new OkAuthenticator(selector());
    }

    public static OkProxySelector selector() {
        if (get().selector != null) return get().selector;
        return get().selector = new OkProxySelector();
    }

    public static synchronized OkHttpClient client() {
        if (get().client != null) return get().client;
        return get().client = getBuilder().build();
    }

    public static synchronized OkHttpClient player() {
        if (get().player != null) return get().player;
        return get().player = getBuilder().build();
    }

    public static OkHttpClient client(long timeout) {
        return client().newBuilder().connectTimeout(timeout, TimeUnit.MILLISECONDS).readTimeout(timeout, TimeUnit.MILLISECONDS).writeTimeout(timeout, TimeUnit.MILLISECONDS).build();
    }

    public static OkHttpClient noRedirect() {
        return noRedirect(TIMEOUT);
    }

    public static OkHttpClient noRedirect(long timeout) {
        return client().newBuilder().connectTimeout(timeout, TimeUnit.MILLISECONDS).readTimeout(timeout, TimeUnit.MILLISECONDS).writeTimeout(timeout, TimeUnit.MILLISECONDS).followRedirects(false).followSslRedirects(false).build();
    }

    public static OkHttpClient client(boolean redirect, long timeout) {
        return redirect ? client(timeout) : noRedirect(timeout);
    }

    public static String string(String url) {
        if (url == null || !url.startsWith("http")) return "";
        try (Response res = newCall(url).execute()) {
            return res.body().string();
        } catch (Exception e) {
            e.printStackTrace();
            return "";
        }
    }

    public static String string(String url, Map<String, String> headers) {
        if (url == null || !url.startsWith("http")) return "";
        try (Response res = newCall(url, headers).execute()) {
            return res.body().string();
        } catch (Exception e) {
            e.printStackTrace();
            return "";
        }
    }

    // --- CatVodSpider app 线常用 API（官方站点源码依赖；R8 后进 spider.merge，KOTV 父优先落到宿主）---
    public static final String POST = "POST";
    public static final String GET = "GET";

    public static String string(String url, Map<String, String> params, Map<String, String> header) {
        if (url == null || !url.startsWith("http")) return "";
        return new OkRequest(GET, url, params, header).execute(client()).getBody();
    }

    public static String string(String url, Map<String, String> params, Map<String, String> header, long timeout) {
        if (url == null || !url.startsWith("http")) return "";
        return new OkRequest(GET, url, params, header).execute(client(timeout)).getBody();
    }

    public static String string(String url, long timeout) {
        return string(url, null, null, timeout);
    }

    public static String post(String url, Map<String, String> params) {
        return post(url, params, null).getBody();
    }

    public static OkResult post(String url, Map<String, String> params, Map<String, String> header) {
        return new OkRequest(POST, url, params, header).execute(client());
    }

    public static String post(String url, String json) {
        return post(url, json, null).getBody();
    }

    public static OkResult post(String url, String json, Map<String, String> header) {
        return new OkRequest(POST, url, json, header).execute(client());
    }

    public static OkResult get(String url, Map<String, String> params, Map<String, String> header) {
        return new OkRequest(GET, url, params, header).execute(client());
    }

    public static OkHttpClient shortTimeoutClient() {
        return client().newBuilder().connectTimeout(5, TimeUnit.SECONDS).readTimeout(5, TimeUnit.SECONDS).writeTimeout(5, TimeUnit.SECONDS).build();
    }

    public static String getLocation(String url, Map<String, String> header) throws java.io.IOException {
        Headers h = safeHeaders(header);
        try (Response res = noRedirect().newCall(req(url).headers(h).build()).execute()) {
            return getLocation(res.headers().toMultimap());
        }
    }

    public static String getLocation(Map<String, java.util.List<String>> headers) {
        if (headers == null) return null;
        if (headers.containsKey("location")) return headers.get("location").get(0);
        if (headers.containsKey("Location")) return headers.get("Location").get(0);
        return null;
    }

    public static Call newCall(Request request) {
        return client().newCall(request);
    }

    public static Call newCall(String url) {
        return client().newCall(req(url).build());
    }

    public static Call newCall(String url, String tag) {
        return client().newCall(req(url).tag(tag).build());
    }

    public static Call newCall(OkHttpClient client, String url) {
        return client.newCall(req(url).build());
    }

    public static Call newCall(OkHttpClient client, String url, String tag) {
        return client.newCall(req(url).tag(tag).build());
    }

    public static Call newCall(String url, Map<String, String> headers) {
        return client().newCall(req(url).headers(safeHeaders(headers)).build());
    }

    public static Call newCall(String url, Map<String, String> headers, ArrayMap<String, String> params) {
        HttpUrl built;
        try {
            built = buildUrl(url, params);
        } catch (IllegalArgumentException e) {
            return client().newCall(req(null).headers(safeHeaders(headers)).build());
        }
        return client().newCall(new Request.Builder().url(built).headers(safeHeaders(headers)).build());
    }

    public static Call newCall(String url, Map<String, String> headers, RequestBody body) {
        return client().newCall(req(url).headers(safeHeaders(headers)).post(body).build());
    }

    public static Call newCall(String url, RequestBody body, String tag) {
        return client().newCall(req(url).post(body).tag(tag).build());
    }

    public static Call newCall(OkHttpClient client, String url, RequestBody body) {
        return client.newCall(req(url).post(body).build());
    }

    /** OkHttp 5 的 Builder.url 是 Kotlin non-null；空/非法 URL 不抛 NPE，交给拦截器立刻失败（同 OkRequest 的空结果语义）。 */
    private static Request.Builder req(String url) {
        HttpUrl parsed = parseHttpUrl(url);
        if (parsed == null) {
            return new Request.Builder()
                    .url(HttpUrl.get("http://127.0.0.1/"))
                    .header("X-KOTV-Invalid-Url", "1");
        }
        return new Request.Builder().url(parsed);
    }

    private static HttpUrl parseHttpUrl(String url) {
        if (url == null) return null;
        String u = url.trim();
        if (u.isEmpty()) return null;
        return HttpUrl.parse(u);
    }

    private static Headers safeHeaders(Map<String, String> headers) {
        if (headers == null || headers.isEmpty()) return new Headers.Builder().build();
        Headers.Builder b = new Headers.Builder();
        for (Map.Entry<String, String> e : headers.entrySet()) {
            if (e.getKey() != null && e.getValue() != null) b.add(e.getKey(), e.getValue());
        }
        return b.build();
    }

    public static void cancel(String tag) {
        cancel(client(), tag);
    }

    public static void cancel(OkHttpClient client, String tag) {
        for (Call call : client.dispatcher().queuedCalls()) if (tag.equals(call.request().tag())) call.cancel();
        for (Call call : client.dispatcher().runningCalls()) if (tag.equals(call.request().tag())) call.cancel();
    }

    public static void cancelAll() {
        cancelAll(client());
    }

    public static void cancelAll(OkHttpClient client) {
        client.dispatcher().cancelAll();
    }

    public static FormBody toBody(ArrayMap<String, String> params) {
        FormBody.Builder body = new FormBody.Builder();
        for (Map.Entry<String, String> entry : params.entrySet()) body.add(entry.getKey(), entry.getValue());
        return body.build();
    }

    private static HttpUrl buildUrl(String url, ArrayMap<String, String> params) {
        String u = url == null ? "" : url.trim();
        HttpUrl parsed = u.isEmpty() ? null : HttpUrl.parse(u);
        if (parsed == null) {
            throw new IllegalArgumentException("url == null");
        }
        HttpUrl.Builder builder = parsed.newBuilder();
        if (params != null) {
            for (Map.Entry<String, String> entry : params.entrySet()) {
                if (entry.getKey() != null && entry.getValue() != null) {
                    builder.addQueryParameter(entry.getKey(), entry.getValue());
                }
            }
        }
        return builder.build();
    }

    private static OkHttpClient.Builder getBuilder() {
        OkHttpClient.Builder builder = new OkHttpClient.Builder().addInterceptor(requestInterceptor()).addInterceptor(authInterceptor()).addNetworkInterceptor(responseInterceptor()).connectTimeout(TIMEOUT, TimeUnit.MILLISECONDS).readTimeout(TIMEOUT, TimeUnit.MILLISECONDS).writeTimeout(TIMEOUT, TimeUnit.MILLISECONDS).dns(dns()).hostnameVerifier((hostname, session) -> true);
        SSLContext ssl = getSSLContext();
        if (ssl != null) {
            builder.sslSocketFactory(ssl.getSocketFactory(), trustAllCertificates());
        }
        HttpLoggingInterceptor logging = new HttpLoggingInterceptor().setLevel(HttpLoggingInterceptor.Level.BODY);
        builder.proxyAuthenticator(authenticator());
        //builder.addNetworkInterceptor(logging);
        builder.proxySelector(selector());
        return builder;
    }

    private static SSLContext getSSLContext() {
        try {
            SSLContext context = SSLContext.getInstance("TLS");
            context.init(null, new TrustManager[]{trustAllCertificates()}, new SecureRandom());
            return context;
        } catch (Throwable e) {
            return null;
        }
    }

    @SuppressLint({"TrustAllX509TrustManager", "CustomX509TrustManager"})
    private static X509TrustManager trustAllCertificates() {
        return new X509TrustManager() {
            @Override
            public void checkClientTrusted(X509Certificate[] chain, String authType) {
            }

            @Override
            public void checkServerTrusted(X509Certificate[] chain, String authType) {
            }

            @Override
            public X509Certificate[] getAcceptedIssuers() {
                return new X509Certificate[0];
            }
        };
    }

    public void clear() {
        cancelAll();
        dns().clear();
        selector().clear();
        authInterceptor().clear();
        requestInterceptor().clear();
        responseInterceptor().clear();
    }

    private static class Loader {
        static volatile OkHttp INSTANCE = new OkHttp();
    }
}
