package com.github.catvod.net.interceptor;

import androidx.annotation.NonNull;

import java.io.IOException;
import java.util.concurrent.ConcurrentHashMap;

import okhttp3.HttpUrl;
import okhttp3.Interceptor;
import okhttp3.Request;
import okhttp3.Response;

public class RequestInterceptor implements Interceptor {

    private final ConcurrentHashMap<String, String> authMap;

    public RequestInterceptor() {
        authMap = new ConcurrentHashMap<>();
    }

    public void clear() {
        authMap.clear();
    }

    @NonNull
    @Override
    public Response intercept(@NonNull Chain chain) throws IOException {
        Request request = chain.request();
        Request.Builder builder = request.newBuilder();
        // 自动带上当前 JAR 调用的 Flutter clientId，供 OkHttp.cancel(clientId) 软取消。
        if (request.tag() == null) {
            try {
                String cid = com.github.catvod.utils.Util.clientId();
                if (cid != null && !cid.isEmpty()) {
                    builder.tag(cid);
                }
            } catch (Throwable ignored) {
            }
        }
        HttpUrl url = request.url();
        checkAuth(url, builder);
        return chain.proceed(builder.build());
    }

    private void checkAuth(HttpUrl url, Request.Builder builder) {
        String host = url.host();
        String auth = url.queryParameter("auth");
        if (auth != null) authMap.put(host, auth);
        else if (authMap.containsKey(host)) builder.url(url.newBuilder().addQueryParameter("auth", authMap.get(host)).build());
    }
}
