package com.bobo.kotv

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.util.Log

/**
 * 原生 MPV 音频焦点：播前申请、停/销毁释放；短暂丢失可恢复、永久丢失不恢复；
 * 耳机拔出等同短暂中断后暂停。
 */
internal class KotvMpvAudioFocus(
  private val appContext: () -> Context?,
  private val main: Handler,
  private val host: Host,
) {
  interface Host {
    fun isPlayerCreated(): Boolean
    fun isPlayingDesired(): Boolean
    fun pauseForAudioInterruption()
    fun resumeAfterAudioFocus()
    fun applyVolumeMultiplier(multiplier: Float)
  }

  private var focusRequest: AudioFocusRequest? = null
  private var hasFocus = false
  private var resumeOnGain = false
  private var volumeMultiplier = 1f
  private var noisyRegistered = false

  private val focusListener =
    AudioManager.OnAudioFocusChangeListener { change ->
      main.post { onFocusChange(change) }
    }

  private val noisyReceiver =
    object : BroadcastReceiver() {
      override fun onReceive(context: Context?, intent: Intent?) {
        if (intent?.action != AudioManager.ACTION_AUDIO_BECOMING_NOISY) return
        main.post {
          if (!host.isPlayerCreated()) return@post
          resumeOnGain = false
          host.pauseForAudioInterruption()
          setNoisyEnabled(false)
        }
      }
    }

  /** @return false 表示拿不到焦点，调用方应保持暂停。 */
  fun requestForPlayback(): Boolean {
    val ctx = appContext() ?: return true
    val am = ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return true
    if (hasFocus) {
      setNoisyEnabled(true)
      return true
    }
    val granted =
      try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
          val req =
            focusRequest
              ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                  AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                    .build(),
                )
                .setOnAudioFocusChangeListener(focusListener, main)
                .setAcceptsDelayedFocusGain(true)
                .build()
                .also { focusRequest = it }
          am.requestAudioFocus(req)
        } else {
          @Suppress("DEPRECATION")
          am.requestAudioFocus(
            focusListener,
            AudioManager.STREAM_MUSIC,
            AudioManager.AUDIOFOCUS_GAIN,
          )
        }
      } catch (t: Throwable) {
        Log.w(TAG, "requestAudioFocus", t)
        return true
      }
    return when (granted) {
      AudioManager.AUDIOFOCUS_REQUEST_GRANTED -> {
        hasFocus = true
        resumeOnGain = false
        restoreVolume()
        setNoisyEnabled(true)
        true
      }
      AudioManager.AUDIOFOCUS_REQUEST_DELAYED -> {
        hasFocus = false
        resumeOnGain = true
        false
      }
      else -> {
        hasFocus = false
        resumeOnGain = false
        false
      }
    }
  }

  fun abandon() {
    resumeOnGain = false
    setNoisyEnabled(false)
    restoreVolume()
    val ctx = appContext() ?: return
    val am = ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
    try {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        focusRequest?.let { am.abandonAudioFocusRequest(it) }
      } else {
        @Suppress("DEPRECATION")
        am.abandonAudioFocus(focusListener)
      }
    } catch (t: Throwable) {
      Log.w(TAG, "abandonAudioFocus", t)
    }
    hasFocus = false
  }

  private fun onFocusChange(change: Int) {
    when (change) {
      AudioManager.AUDIOFOCUS_GAIN -> {
        hasFocus = true
        restoreVolume()
        if (resumeOnGain) {
          resumeOnGain = false
          if (host.isPlayerCreated()) host.resumeAfterAudioFocus()
        }
        if (host.isPlayingDesired()) setNoisyEnabled(true)
      }
      AudioManager.AUDIOFOCUS_LOSS -> {
        hasFocus = false
        resumeOnGain = false
        restoreVolume()
        if (host.isPlayerCreated()) host.pauseForAudioInterruption()
        setNoisyEnabled(false)
        abandon()
      }
      AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
        hasFocus = false
        resumeOnGain = host.isPlayingDesired()
        restoreVolume()
        if (host.isPlayerCreated()) host.pauseForAudioInterruption()
        setNoisyEnabled(false)
      }
      AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
        volumeMultiplier = DUCK
        host.applyVolumeMultiplier(volumeMultiplier)
      }
    }
  }

  private fun restoreVolume() {
    if (volumeMultiplier == 1f) return
    volumeMultiplier = 1f
    host.applyVolumeMultiplier(1f)
  }

  private fun setNoisyEnabled(enabled: Boolean) {
    val ctx = appContext() ?: return
    if (enabled == noisyRegistered) return
    try {
      if (enabled) {
        ctx.registerLocalReceiver(noisyReceiver, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY))
        noisyRegistered = true
      } else {
        ctx.unregisterReceiver(noisyReceiver)
        noisyRegistered = false
      }
    } catch (t: Throwable) {
      Log.w(TAG, "noisy receiver", t)
      noisyRegistered = false
    }
  }

  companion object {
    private const val TAG = "KotvMpvAudioFocus"
    private const val DUCK = 0.2f
  }
}
