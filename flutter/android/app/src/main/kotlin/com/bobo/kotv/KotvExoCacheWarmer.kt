package com.bobo.kotv

import android.content.Context
import android.net.Uri
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheWriter
import androidx.media3.datasource.okhttp.OkHttpDataSource
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.atomic.AtomicLong
import okhttp3.OkHttpClient

/** 将下一集媒体前段写入 SimpleCache，切集时可直接命中磁盘缓存。 */
@OptIn(UnstableApi::class)
object KotvExoCacheWarmer {
  private const val TAG = "KotvExoCacheWarmer"
  private val executor = Executors.newSingleThreadExecutor { r ->
    Thread(r, "kotv-exo-warm").apply { isDaemon = true }
  }
  private val gen = AtomicLong(0)
  @Volatile
  private var running: Future<*>? = null

  fun cancel() {
    gen.incrementAndGet()
    try {
      running?.cancel(true)
    } catch (_: Throwable) {
    }
    running = null
  }

  fun warm(
    ctx: Context,
    http: OkHttpClient,
    url: String,
    headers: Map<String, String>,
    maxBytes: Long,
  ) {
    val u = url.trim()
    if (u.isEmpty() || maxBytes <= 0L) return
    val token = gen.incrementAndGet()
    try {
      running?.cancel(true)
    } catch (_: Throwable) {
    }
    running =
      executor.submit {
        if (token != gen.get()) return@submit
        try {
          val cache = KotvExoCache.get(ctx)
          val factory =
            OkHttpDataSource.Factory(http)
              .setUserAgent(headers["User-Agent"] ?: headers["user-agent"] ?: "KOTV")
              .setDefaultRequestProperties(headers)
          val upstream = DefaultDataSource.Factory(ctx, factory)
          val cacheDs =
            CacheDataSource.Factory()
              .setCache(cache)
              .setUpstreamDataSourceFactory(upstream)
              .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
              .createDataSource()
          // FongMi Media3：Builder 仅接受 DataSpec 拷贝构造，URI 用 setUri。
          val spec =
            DataSpec.Builder()
              .setUri(Uri.parse(u))
              .setLength(maxBytes.coerceIn(256L * 1024L, 64L * 1024L * 1024L))
              .build()
          CacheWriter(cacheDs, spec, /* temporaryBuffer= */ null, /* progressListener= */ null).cache()
          Log.i(TAG, "warmed ${maxBytes}B for $u")
        } catch (t: Throwable) {
          if (token == gen.get()) Log.w(TAG, "warm failed: $u", t)
        }
      }
  }
}
