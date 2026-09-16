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

  fun get(ctx: Context, maxBytes: Long = defaultMaxBytes(ctx)): Cache {
    cache?.let { return it }
    synchronized(this) {
      cache?.let { return it }
      val dir = File(ctx.cacheDir, "exo").apply { mkdirs() }
      val created =
        SimpleCache(
          dir,
          LeastRecentlyUsedCacheEvictor(maxBytes.coerceAtLeast(32L * 1024 * 1024)),
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
