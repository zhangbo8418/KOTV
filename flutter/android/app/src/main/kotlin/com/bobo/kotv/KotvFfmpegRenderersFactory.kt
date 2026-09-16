package com.bobo.kotv

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.DolbyVisionOutputPolicy
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.Renderer
import androidx.media3.exoplayer.audio.AudioRendererEventListener
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.AudioTrackAudioOutputProvider
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.text.TextOutput
import androidx.media3.exoplayer.text.TextRenderer
import io.github.anilbeesetti.nextlib.media3ext.ffdecoder.FfmpegAudioRenderer
import io.github.anilbeesetti.nextlib.media3ext.ffdecoder.FfmpegLibrary

/**
 * Exo 渲染工厂：视频走 MediaCodec，音轨走 nextlib FFmpeg（含 AV3A/libarcdav3a）。
 * 可选第二路 TextRenderer（双字幕）与 DV/直通。
 */
@OptIn(UnstableApi::class)
class KotvFfmpegRenderersFactory(
  context: Context,
  private val videoExtensionMode: Int,
  private val audioExtensionMode: Int,
  dolbyVisionPolicy: Int = DolbyVisionOutputPolicy.AUTO,
  private val audioPassThrough: Boolean = true,
  private val secondaryTextOutput: TextOutput? = null,
) : DefaultRenderersFactory(context) {

  init {
    setEnableDecoderFallback(true)
    setExtensionRendererMode(maxOf(videoExtensionMode, audioExtensionMode))
    val policy =
      when (dolbyVisionPolicy) {
        DolbyVisionOutputPolicy.ASSUME_SUPPORTED,
        DolbyVisionOutputPolicy.ASSUME_UNSUPPORTED,
        -> dolbyVisionPolicy
        else -> DolbyVisionOutputPolicy.AUTO
      }
    setDolbyVisionOutputPolicy(policy)
  }

  override fun buildAudioSink(
    context: Context,
    enableFloatOutput: Boolean,
    enableAudioTrackPlaybackParams: Boolean,
  ): AudioSink {
    val builder =
      DefaultAudioSink.Builder(context)
        .setEnableFloatOutput(enableFloatOutput)
        .setEnableAudioTrackPlaybackParams(enableAudioTrackPlaybackParams)
    if (!audioPassThrough) {
      builder.setAudioOutputProvider(AudioTrackAudioOutputProvider.Builder(null).build())
    }
    return builder.build()
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

  override fun buildTextRenderers(
    context: Context,
    output: TextOutput,
    outputLooper: Looper,
    extensionRendererMode: Int,
    out: ArrayList<Renderer>,
  ) {
    super.buildTextRenderers(context, output, outputLooper, extensionRendererMode, out)
    val secondary = secondaryTextOutput
    if (secondary != null) {
      out.add(TextRenderer(secondary, outputLooper))
    }
  }
}
