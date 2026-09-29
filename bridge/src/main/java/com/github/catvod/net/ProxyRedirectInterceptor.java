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
 * 最多跟 20 次，防环。
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
      String location = response.header("Location");
      if (location == null || location.isEmpty()) break;
      HttpUrl next = response.request().url().resolve(location);
      if (next == null) break;
      String nextStr = next.toString();
      if (!seen.add(nextStr)) break;
      response.close();
      Request.Builder b = request.newBuilder().url(next);
      if (response.code() == 302 || response.code() == 303) {
        b.method("GET", null);
      }
      request = b.build();
      response = chain.proceed(request);
      hops++;
    }
    return response;
  }

  private static boolean isRedirect(int code) {
    return code == 301 || code == 302 || code == 303 || code == 307 || code == 308;
  }
}
