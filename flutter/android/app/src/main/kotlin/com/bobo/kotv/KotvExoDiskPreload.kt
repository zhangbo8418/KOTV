package com.bobo.kotv

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.PriorityTaskManager
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.RenderersFactory
import androidx.media3.exoplayer.source.preload.DiskPreloadManager

/** 点播边播边向 SimpleCache 预读。 */
@OptIn(UnstableApi::class)
class KotvExoDiskPreload {
  private val priorityTaskManager = PriorityTaskManager()
  private var manager: DiskPreloadManager? = null

  fun start(
    ctx: Context,
    player: ExoPlayer,
    mediaItem: MediaItem,
    upstream: DataSource.Factory,
    renderers: RenderersFactory,
    durationMs: Long = 10_000L,
    maxThreads: Int = 2,
  ) {
    stop()
    val m =
      DiskPreloadManager.Builder(KotvExoCache.get(ctx), upstream, renderers)
        .setPriorityTaskManager(priorityTaskManager)
        .build()
    manager = m
    player.setPriorityTaskManager(priorityTaskManager)
    val options =
      DiskPreloadManager.Options.builder()
        .setDurationMs(durationMs.coerceIn(5_000L, 120_000L))
        .setMaxThreads(maxThreads.coerceIn(1, 10))
        .build()
    m.start(player, mediaItem, options)
  }

  fun stop() {
    try {
      manager?.release()
    } catch (_: Throwable) {
    }
    manager = null
  }
}
