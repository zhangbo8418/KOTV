package com.bobo.kotv

import android.content.Context
import android.os.Handler
import androidx.annotation.OptIn
import androidx.media3.common.DolbyVisionOutputPolicy
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.audio.AudioRendererEventListener
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import io.github.anilbeesetti.nextlib.media3ext.ffdecoder.FfmpegAudioRenderer
import io.github.anilbeesetti.nextlib.media3ext.ffdecoder.FfmpegLibrary

/**
 * Exo 渲染工厂：视频走 MediaCodec，音轨走 nextlib FFmpeg（含 AV3A/libarcdav3a）。
 *
 * DV / 扩展渲染策略：
 * decoder fallback + DolbyVisionOutputPolicy.AUTO。
 */
@OptIn(UnstableApi::class)
class KotvFfmpegRenderersFactory(
  context: Context,
  private val videoExtensionMode: Int,
  private val audioExtensionMode: Int,
) : DefaultRenderersFactory(context) {

  init {
    setEnableDecoderFallback(true)
    setExtensionRendererMode(maxOf(videoExtensionMode, audioExtensionMode))
    setDolbyVisionOutputPolicy(DolbyVisionOutputPolicy.AUTO)
  }

  override fun buildAudioRenderers(
    context: Context,
    extensionRendererMode: Int,
    mediaCodecSelector: MediaCodecSelector,
    enableDecoderFallback: Boolean,
    audioSink: AudioSink,
    eventHandler: Handler,
    eventListener: AudioRendererEventListener,
    out: ArrayList<Renderer>,
  ) {
    super.buildAudioRenderers(
      context,
      audioExtensionMode,
      mediaCodecSelector,
      enableDecoderFallback,
      audioSink,
      eventHandler,
      eventListener,
      out,
    )
    if (audioExtensionMode != EXTENSION_RENDERER_MODE_OFF && FfmpegLibrary.isAvailable()) {
      out.add(
        FfmpegAudioRenderer(
          eventHandler,
          eventListener,
          audioSink,
        ),
      )
    }
  }

  override fun buildVideoRenderers(
    context: Context,
    extensionRendererMode: Int,
    mediaCodecSelector: MediaCodecSelector,
    enableDecoderFallback: Boolean,
    eventHandler: Handler,
    eventListener: androidx.media3.exoplayer.video.VideoRendererEventListener,
    allowedVideoJoiningTimeMs: Long,
    out: ArrayList<Renderer>,
  ) {
    super.buildVideoRenderers(
      context,
      videoExtensionMode,
      mediaCodecSelector,
      enableDecoderFallback,
      eventHandler,
      eventListener,
      allowedVideoJoiningTimeMs,
      out,
    )
  }
}
