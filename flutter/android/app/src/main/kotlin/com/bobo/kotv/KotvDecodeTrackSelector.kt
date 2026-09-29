package com.bobo.kotv

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.TrackGroup
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.RendererCapabilities
import androidx.media3.exoplayer.trackselection.DecodeTrackSelector

/**
 * 硬解偏好时：即便 [C.FORMAT_EXCEEDS_CAPABILITIES]（常见于 HEVC profileLevel 虚高如 L186）
 * 仍优先 MediaCodec，避免过早落到帧率崩坏的 FFmpeg 软解。
 * 软解偏好仍走父类「只允许 FFmpeg」逻辑。
 */
@OptIn(UnstableApi::class)
class KotvDecodeTrackSelector(context: Context) : DecodeTrackSelector(context) {

  @Volatile private var videoDecode: Int = C.DECODE_HARDWARE
  @Volatile private var audioDecode: Int = C.DECODE_HARDWARE

  /** 父类 [setRendererDecodePreferences] 为 final，额外记一份供 EXCEEDS 硬解偏好判断。 */
  fun applyDecodePreferences(audioDecode: Int, videoDecode: Int) {
    this.audioDecode = audioDecode
    this.videoDecode = videoDecode
    setRendererDecodePreferences(audioDecode, videoDecode)
  }

  override fun isPreferredRenderer(
    rendererCapability: RendererCapabilities,
    group: TrackGroup,
    @C.FormatSupport formatSupportLevel: Int,
  ): Boolean {
    if (super.isPreferredRenderer(rendererCapability, group, formatSupportLevel)) {
      return true
    }
    if (group.type != C.TRACK_TYPE_AUDIO && group.type != C.TRACK_TYPE_VIDEO) {
      return false
    }
    if (rendererCapability.trackType != group.type) {
      return false
    }
    val decode = if (group.type == C.TRACK_TYPE_AUDIO) audioDecode else videoDecode
    if (decode != C.DECODE_HARDWARE) {
      return false
    }
    if (formatSupportLevel != C.FORMAT_EXCEEDS_CAPABILITIES) {
      return false
    }
    val name = rendererCapability.name
    return when (group.type) {
      C.TRACK_TYPE_VIDEO -> name == "MediaCodecVideoRenderer"
      C.TRACK_TYPE_AUDIO -> name == "MediaCodecAudioRenderer"
      else -> false
    }
  }
}
