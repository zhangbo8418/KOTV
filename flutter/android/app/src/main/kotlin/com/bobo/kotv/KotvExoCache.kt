package com.bobo.kotv

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.cache.Cache
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import java.io.File

/** Exo 点播磁盘缓存（SimpleCache + LRU）。 */
@OptIn(UnstableApi::class)
object KotvExoCache {
  @Volatile
  private var cache: Cache? = null
  @Volatile
  private var preferredMaxBytes: Long = 0L

  /** 在首次创建缓存前生效；已创建后保留偏好供下次冷启动。 */
  fun preferMaxBytes(bytes: Long) {
    preferredMaxBytes = bytes.coerceIn(128L * 1024 * 1024, 4L * 1024 * 1024 * 1024)
  }

  fun get(ctx: Context, maxBytes: Long = 0L): Cache {
    cache?.let { return it }
    synchronized(this) {
      cache?.let { return it }
      val limit =
        when {
          maxBytes > 0L -> maxBytes
          preferredMaxBytes > 0L -> preferredMaxBytes
          else -> defaultMaxBytes(ctx)
        }.coerceAtLeast(32L * 1024 * 1024)
      val dir = File(ctx.cacheDir, "exo").apply { mkdirs() }
      val created =
        SimpleCache(
          dir,
          LeastRecentlyUsedCacheEvictor(limit),
          StandaloneDatabaseProvider(ctx),
        )
      cache = created
      return created
    }
  }

  private fun defaultMaxBytes(ctx: Context): Long {
    val free = ctx.cacheDir.usableSpace.coerceAtLeast(0)
    // 最多占用可用空间的 20%，钳到 256MiB–2GiB。
    return (free * 0.2).toLong().coerceIn(256L * 1024 * 1024, 2L * 1024 * 1024 * 1024)
  }
}
