package com.github.catvod.net;

import java.io.IOException;
import java.util.Collections;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import okhttp3.HttpUrl;
import okhttp3.Interceptor;
import okhttp3.Request;
import okhttp3.Response;

/**
 * 关闭 OkHttp 自动跟跳后，按 Location 手动跟随，便于代理按 host 切换。
 * 最多跟 20 次，防环。跨域剥 Authorization，避免鉴权头带到新 host。
 */
public final class ProxyRedirectInterceptor implements Interceptor {

  private static final int MAX_HOPS = 20;

  @Override
  public Response intercept(Chain chain) throws IOException {
    Request request = chain.request();
    Response response = chain.proceed(request);
    Set<String> seen = Collections.newSetFromMap(new ConcurrentHashMap<>());
    seen.add(request.url().toString());
    int hops = 0;
    while (isRedirect(response.code()) && hops < MAX_HOPS) {
      Request followUp = redirectRequest(response);
      if (followUp == null) break;
      String nextStr = followUp.url().toString();
      if (!seen.add(nextStr)) break;
      response.close();
      request = followUp;
      response = chain.proceed(request);
      hops++;
    }
    return response;
  }

  private static Request redirectRequest(Response response) {
    String location = response.header("Location");
    if (location == null || location.isEmpty()) return null;
    HttpUrl source = response.request().url();
    HttpUrl target = source.resolve(location);
    if (target == null) return null;
    Request.Builder builder = response.request().newBuilder().url(target);
    String method = response.request().method();
    int code = response.code();
    if (!"GET".equals(method) && !"HEAD".equals(method)) {
      if (redirectsToGet(method, code)) {
        builder.method("GET", null)
            .removeHeader("Transfer-Encoding")
            .removeHeader("Content-Length")
            .removeHeader("Content-Type");
      }
    }
    if (!source.scheme().equals(target.scheme())
        || !source.host().equals(target.host())
        || source.port() != target.port()) {
      builder.removeHeader("Authorization");
    }
    return builder.build();
  }

  private static boolean redirectsToGet(String method, int code) {
    if (code == 303) return !"PROPFIND".equals(method);
    if (code == 307 || code == 308) return false;
    // 301/302/300：常见客户端对非 GET/HEAD 转 GET（PROPFIND/QUERY 除外）
    return !"PROPFIND".equals(method) && !"QUERY".equals(method);
  }

  private static boolean isRedirect(int code) {
    return code == 300 || code == 301 || code == 302 || code == 303 || code == 307 || code == 308;
  }
}
