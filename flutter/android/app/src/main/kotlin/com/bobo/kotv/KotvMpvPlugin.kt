package com.bobo.kotv

import android.content.Context
import android.content.IntentFilter
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.SurfaceTexture
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.Gravity
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import `is`.xyz.mpv.MPVLib
import java.io.File
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.roundToInt
import org.json.JSONArray
import org.json.JSONObject

/**
 * 安卓自研 MPV：[MPVLib] + SurfaceView/TextureView（PlayerView.setRender）。
 * 套件在 jniLibs；assets/mpv-libs 只留 Vulkan stub。
 */
class KotvMpvPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler,
  MPVLib.EventObserver {

  private var channel: MethodChannel? = null
  private var events: EventChannel? = null
  private var eventSink: EventChannel.EventSink? = null
  private var appContext: Context? = null
  private var surfaceHost: KotvMpvSurfaceHost? = null

  private val main = Handler(Looper.getMainLooper())
  /** 每次 load 请求递增；[activeLoadGen] 在 START_FILE 时对齐，用于丢弃过期 end-file。 */
  private val loadGen = AtomicInteger(0)
  @Volatile private var activeLoadGen = 0
  private val created = AtomicBoolean(false)
  private var playing = false
  private var buffering = false
  private var paused = false
  private var durationSec = 0.0
  /** 优先于 [durationSec]：HLS 整表时长（mpv `duration/full`）。 */
  private var durationFullSec = 0.0
  private var positionSec = 0.0
  private var width = 0
  private var height = 0
  private var eof = false
  /** 单集循环；重建 mpv 实例时要重新写入 loop-file。 */
  private var repeatOne = false
  private var pendingUrl: String? = null
  private var pendingHeaders: Map<String, String> = emptyMap()
  private var surfaceReady = false
  /** 同一 Surface 只更新尺寸（attachedSurface）。 */
  private var attachedSurface: Surface? = null
  private var surfaceAttached = false
  private var appliedSurfaceSize: String? = null
  private var decodeMode = "auto"
  private var gpuNext = false
  private var vulkanEnabled = false
  private var conf = ""
  /** 默认校验证书；坏 CA 盒子可关（设置 mpvTlsVerify=false）。 */
  private var tlsVerify = true
  /** 音频直通（audio-spdif）。 */
  private var audioPassThrough = true
  /** 点播磁盘缓存。 */
  private var diskCache = false
  /** 杜比视界策略：0=AUTO 1=假定支持 2=假定不支持（与 exoDolbyVision 枚举一致）。 */
  private var dolbyVisionPolicy = 0
  /** 当前是否允许杜比视界直出（android-dolby-vision-output=direct）。 */
  private var dvDirect = false
  /** 当前上下文是否以硬解直出建立（vo=mediacodec_embed）；null = 尚未建立。 */
  private var createdDirect: Boolean? = null
  /** mpv 正在用直出 vo（含杜比视界自动换成的直出）；此时画面比例由宿主摆放 SurfaceView。 */
  private var directActive = false
  /** 片源显示比例（video-params/aspect）。 */
  private var videoAspect = 0.0
  /** 已交给 mpv 的 OSD Surface（android-osd-wid）。 */
  private var attachedOsdSurface: Surface? = null
  private var appliedOsdSize: String? = null
  /** 首选字幕语言（BCP-47，逗号分隔）→ mpv slang。 */
  private var preferredTextLangs = ""
  /** 开播标定的直播会话；点播勿被引擎 media-live 改写（否则 queueNext 被拒）。 */
  private var livePlayback = false
  /** 引擎 media-live：只影响缓冲/磁盘缓存，不挡无缝排队。 */
  private var engineLive = false
  /** 已按 media-live 升过会话，避免重复重建。 */
  private var upgradedLiveFromMedia = false
  /** 错误恢复后 seek 到该秒；&lt;0 表示不恢复。 */
  private var retrySeekSec = -1.0
  /** open(startAtMs)：loadfile 后、unpause 前 seek，避免 play 后再 seek。 */
  private var pendingStartAtMs = 0L
  private var loadedUrl: String = ""
  private var loadedHeaders: Map<String, String> = emptyMap()
  /** Dart [kotvPlayMime]；HLS 时在 loadfile 写 demuxer-lavf-format=hls。 */
  private var currentMime: String? = null
  private var retriedHlsMime = false
  private var retriedDecodeFallback = false
  /** 前向缓冲字节顶，由 Dart KotvBufferBudget 下发；变更须重建上下文。 */
  private var bufferBytes = 0
  /** 排在 mpv 播放列表第 2 项的下一集；播到它时由 playlist-pos 切成当前集。mpv 事件线程也会读。 */
  @Volatile private var queuedNext: KotvQueuedNext? = null
  /** 正在 playlist-next 切入排队项；挡住旧文件 end-file 误报 completed。 */
  @Volatile private var pendingSeamlessId: String? = null
  private var volume = 80.0
  private var rate = 1.0
  /** 画面调色（mpv brightness/contrast/… ∈ [-100,100]）。 */
  private var eqBrightness = 0
  private var eqContrast = 0
  private var eqSaturation = 0
  private var eqGamma = 0
  private var eqHue = 0
  /** 音频 af；空=不套。 */
  private var audioAf = ""
  /** 画面 vf（锐度等）；空=清掉。 */
  private var videoVf = ""
  private var renderTexture = false
  /** 点播挂 Surface；停播卸下（未点播不建，避免详情滑动重影）。 */
  private var surfaceLayerEnabled = false
  /** default|fill|zoom|16:9|4:3 — Surface 不吃 Flutter BoxFit，用 keepaspect/panscan/override。 */
  private var aspectMode: String = "default"
  /** ensurePlayer 时是否按直播初始化（磁盘缓存和 cache-pause 不同，模式变了须重建）。 */
  private var createdAsLive: Boolean? = null
  /** ensurePlayer 时写入的 tls-verify；变更须重建上下文。 */
  private var createdTlsVerify: Boolean? = null
  private var createdDiskCache: Boolean? = null
  /** ensurePlayer 时写入的 demuxer 字节预算；变更须重建上下文。 */
  private var createdBufferBytes: Int? = null
  /** 最近一次写入的 audio-spdif；空=当前输出不直通。 */
  private var appliedSpdif: String? = null
  /** 本次 loadfile / 无缝切入的墙钟；用于识别「开播即 seek 末帧」假片尾。 */
  private var loadWallMs = 0L
  /** 正向播放中见到的最大 time-pos（seek 到末帧不计入）。 */
  private var maxPlayedSec = 0.0
  /** AudioFocus duck 乘子；用户音量仍存 [volume]。 */
  private var audioFocusVolumeMul = 1f
  /** 音画偏移（秒），对应 mpv `audio-delay`。 */
  private var audioDelaySec = 0.0
  private val audioFocus by lazy {
    KotvMpvAudioFocus(
      appContext = { appContext },
      main = main,
      host =
        object : KotvMpvAudioFocus.Host {
          override fun isPlayerCreated(): Boolean = created.get()

          override fun isPlayingDesired(): Boolean = !paused && playing

          override fun pauseForAudioInterruption() {
            if (!created.get()) return
            try {
              MPVLib.setPropertyBoolean("pause", true)
            } catch (_: Throwable) {
            }
            paused = true
            playing = false
          }

          override fun resumeAfterAudioFocus() {
            if (!created.get()) return
            try {
              MPVLib.setPropertyBoolean("pause", false)
            } catch (_: Throwable) {
            }
            paused = false
            playing = true
          }

          override fun applyVolumeMultiplier(multiplier: Float) {
            audioFocusVolumeMul = multiplier.coerceIn(0f, 1f)
            applyVolumeProperty()
          }
        },
    )
  }

  private val tick = object : Runnable {
    override fun run() {
      if (!created.get()) return
      try {
        val pos = MPVLib.getPropertyDouble("time-pos") ?: positionSec
        val durProp = MPVLib.getPropertyDouble("duration")
        if (durProp != null && durProp > 0) durationSec = durProp
        val fullProp = MPVLib.getPropertyDouble("duration/full")
        if (fullProp != null && fullProp > 0) durationFullSec = fullProp
        val dur = effectiveDurationSec()
        val pause = MPVLib.getPropertyBoolean("pause") ?: paused
        val idle = MPVLib.getPropertyBoolean("idle-active") ?: false
        val coreIdle = MPVLib.getPropertyBoolean("core-idle") ?: false
        val seeking = MPVLib.getPropertyBoolean("seeking") ?: false
        val pausedForCache = MPVLib.getPropertyBoolean("paused-for-cache") ?: false
        positionSec = pos
        paused = pause
        playing = !pause && !idle && !coreIdle
        if (playing && !seeking && !eof && pos > maxPlayedSec) {
          maxPlayedSec = pos
        }
        buffering = seeking || pausedForCache || (!playing && !eof && pendingUrl == null && pos <= 0.05)
        val bufSec = MPVLib.getPropertyDouble("demuxer-cache-duration") ?: 0.0
        val speed = ((MPVLib.getPropertyDouble("cache-speed") ?: 0.0)).toLong().coerceAtLeast(0)
        emit(
          mapOf(
            "event" to "position",
            "positionMs" to (pos * 1000).toLong(),
            "durationMs" to (dur * 1000).toLong().coerceAtLeast(0),
            "bufferedMs" to ((pos + bufSec) * 1000).toLong().coerceAtLeast(0),
            "playing" to playing,
            "buffering" to buffering,
            "speedBps" to speed,
          ),
        )
      } catch (e: Throwable) {
        Log.w(TAG, "tick", e)
      }
      main.postDelayed(this, 300)
    }
  }

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    appContext = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, "kotv_mpv").also {
      it.setMethodCallHandler(this)
    }
    events = EventChannel(binding.binaryMessenger, "kotv_mpv/events").also {
      it.setStreamHandler(this)
    }
    binding.platformViewRegistry.registerViewFactory(
      VIEW_TYPE,
      KotvMpvSurfaceFactory(this),
    )
    Log.i(TAG, "KotvMpvPlugin attached")
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    destroyPlayer()
    channel?.setMethodCallHandler(null)
    channel = null
    events?.setStreamHandler(null)
    events = null
    eventSink = null
    appContext = null
  }

  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
    eventSink = events
  }

  override fun onCancel(arguments: Any?) {
    eventSink = null
  }

  internal fun attachSurfaceHost(host: KotvMpvSurfaceHost) {
    surfaceHost = host
    host.onSurface = { ready ->
      surfaceReady = ready
      if (ready) {
        tryAttachSurface()
        maybeLoadPending()
      } else if (created.get()) {
        // 短暂丢 Surface（全屏改 LayoutParams）只 detach，保留 VO，勿 vo=null。
        parkSurfaceTransient()
      }
    }
    host.onSurfaceSize = { w, h -> if (surfaceHost === host) applySurfaceSize("${w}x$h") }
    host.onOsdSurface = { if (surfaceHost === host) syncOsdSurface() }
    host.setOsdLayer(osdWanted())
    if (surfaceLayerEnabled) {
      host.setRender(renderTexture)
      if (host.currentSurface() != null) {
        surfaceReady = true
        tryAttachSurface()
        maybeLoadPending()
      }
    } else {
      host.clearVideoLayer()
      surfaceReady = false
    }
  }

  internal fun detachSurfaceHost(host: KotvMpvSurfaceHost) {
    if (surfaceHost === host) {
      surfaceHost = null
      surfaceReady = false
      // PlatformView 真正卸树：clearVideoOutput，vo=null。
      parkSurfaceTerminal()
    }
  }

  /** 短暂丢 Surface（全屏改布局等）：只卸 Surface，保留 vo。 */
  private fun parkSurfaceTransient() {
    detachOsdSurface()
    if (!created.get() || !surfaceAttached) {
      attachedSurface = null
      surfaceAttached = false
      return
    }
    try {
      MPVLib.detachSurface()
    } catch (_: Throwable) {
    }
    attachedSurface = null
    surfaceAttached = false
    appliedSurfaceSize = null
  }

  /** PlatformView 卸树：vo=null 并卸 Surface。 */
  private fun parkSurfaceTerminal() {
    detachOsdSurface()
    if (!created.get()) {
      attachedSurface = null
      surfaceAttached = false
      appliedSurfaceSize = null
      return
    }
    try {
      MPVLib.setPropertyString("vo", "null")
      MPVLib.setPropertyString("force-window", "no")
      MPVLib.detachSurface()
    } catch (_: Throwable) {
    }
    attachedSurface = null
    surfaceAttached = false
    appliedSurfaceSize = null
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "isVulkanAvailable" -> {
        // 设备 Vulkan≥1.2：设置页是否露出开关。
        val ctx = appContext
        result.success(ctx != null && MPVLib.isDeviceVulkanCapable(ctx))
      }
      "create" -> {
        ingestPlayerArgs(call)
        // 直播须在 ensurePlayer 前写入，磁盘缓存和 cache-pause 按这次会话来。
        call.argument<Boolean>("live")?.let { livePlayback = it }
        call.argument<Boolean>("repeatOne")?.let { repeatOne = it }
        call.argument<String>("render")?.trim()?.takeIf { it.isNotEmpty() }?.let {
          renderTexture = resolveRenderTexture(it)
        }
        main.post {
          try {
            if (surfaceLayerEnabled) {
              surfaceHost?.setRender(renderTexture)
            } else {
              surfaceHost?.clearVideoLayer()
            }
            ensurePlayer()
            applyRepeatOne()
            result.success(mapOf("ok" to true, "ready" to created.get()))
          } catch (e: Throwable) {
            emitLoadFailure(e)
            result.error("CREATE_FAILED", e.message, null)
          }
        }
      }
      "open" -> {
        val url = call.argument<String>("url") ?: ""
        val headers = stringMapArg(call, "headers")
        livePlayback = call.argument<Boolean>("live") == true
        ingestPlayerArgs(call)
        ingestEqualizerArgs(call)
        call.argument<String>("render")?.trim()?.takeIf { it.isNotEmpty() }?.let {
          renderTexture = resolveRenderTexture(it)
        }
        pendingStartAtMs = call.argument<Number>("startAtMs")?.toLong()?.takeIf { it > 0L } ?: 0L
        val props = stringMapArg(call, "props")
        main.post {
          try {
            surfaceHost?.let { host ->
              if (surfaceLayerEnabled) host.setRender(renderTexture) else host.clearVideoLayer()
            }
            // 会话内复用 libmpv 上下文；仅 loadfile replace。
            ensurePlayer()
            applyRuntimeOpts(props)
            applyGpuApiIfNeeded()
            applyDolbyVisionOptions()
            applyPreferredSubtitleLangs()
            applyEqualizer()
            applyAspectMode()
            eof = false
            buffering = true
            playing = false
            positionSec = 0.0
            durationSec = 0.0
            durationFullSec = 0.0
            engineLive = false
            upgradedLiveFromMedia = livePlayback
            width = 0
            height = 0
            maxPlayedSec = 0.0
            loadWallMs = SystemClock.elapsedRealtime()
            // 作废上一集还没落地的失败重试。
            loadGen.incrementAndGet()
            retrySeekSec = -1.0
            currentMime = call.argument<String>("mime")?.trim()?.ifEmpty { null }
            retriedHlsMime = false
            retriedDecodeFallback = false
            pendingUrl = url
            pendingHeaders = headers
            loadedUrl = ""
            loadedHeaders = emptyMap()
            // 有 Surface 再 loadfile，避免 android VO「Missing surface pointer」有声无画。
            maybeLoadPending()
            result.success(null)
          } catch (e: Throwable) {
            emitLoadFailure(e)
            result.error("OPEN_FAILED", e.message, null)
          }
        }
      }
      "play" -> {
        main.post {
          try {
            if (!created.get()) {
              result.success(null)
              return@post
            }
            // keep-open 片尾后再播：先回起点，避免只 unpause 停在 EOF。
            if (eof || (effectiveDurationSec() > 1.0 &&
                positionSec >= effectiveDurationSec() - 0.35)
            ) {
              try {
                MPVLib.command(arrayOf("seek", "0", "absolute"))
              } catch (_: Throwable) {
              }
              eof = false
              positionSec = 0.0
            }
            unpauseWithAudioFocus()
            result.success(null)
          } catch (e: Throwable) {
            result.error("PLAY_FAILED", e.message, null)
          }
        }
      }
      "setAudioOffsetMs" -> {
        val ms = call.argument<Number>("ms")?.toDouble() ?: 0.0
        audioDelaySec = (ms / 1000.0).coerceIn(-10.0, 10.0)
        main.post {
          try {
            applyAudioDelay()
            result.success(null)
          } catch (e: Throwable) {
            result.error("AUDIO_OFFSET_FAILED", e.message, null)
          }
        }
      }
      "pause" -> {
        main.post {
          try {
            if (!created.get()) {
              result.success(null)
              return@post
            }
            MPVLib.setPropertyBoolean("pause", true)
            paused = true
            playing = false
            audioFocus.abandon()
            result.success(null)
          } catch (e: Throwable) {
            result.error("PAUSE_FAILED", e.message, null)
          }
        }
      }
      "queueNext" -> {
        val next =
          KotvQueuedNext(
            id = call.argument<String>("id")?.trim().orEmpty(),
            url = call.argument<String>("url")?.trim().orEmpty(),
            headers = KotvPlayerNormalize.normalizeHeaders(stringMapArg(call, "headers")),
            mime = call.argument<String>("mime")?.trim()?.ifEmpty { null },
            subs = listMapArg(call, "subs"),
            startAtMs = call.argument<Number>("startAtMs")?.toLong()?.takeIf { it > 0L } ?: 0L,
          )
        main.post { result.success(queueNext(next)) }
      }
      "clearNext" -> {
        main.post {
          clearQueuedNext()
          result.success(null)
        }
      }
      "skipToNext" -> {
        main.post {
          val next = queuedNext
          result.success(next != null && skipToQueued(next))
        }
      }
      "stop" -> {
        main.post {
          try {
            pendingUrl = null
            // 作废进行中的 loadfile。换集只卸文件，上下文留到 dispose 或模式变化再拆。
            loadGen.incrementAndGet()
            if (created.get()) {
              MPVLib.command(arrayOf("stop"))
            }
            playing = false
            buffering = false
            paused = true
            eof = false
            width = 0
            height = 0
            positionSec = 0.0
            durationSec = 0.0
            durationFullSec = 0.0
            engineLive = false
            upgradedLiveFromMedia = false
            loadedUrl = ""
            currentMime = null
            retriedHlsMime = false
            retriedDecodeFallback = false
            queuedNext = null
            pendingSeamlessId = null
            audioFocus.abandon()
            result.success(null)
          } catch (e: Throwable) {
            result.error("STOP_FAILED", e.message, null)
          }
        }
      }
      "seek" -> {
        val ms = (call.argument<Number>("positionMs") ?: 0).toLong()
        main.post {
          try {
            if (created.get()) {
              MPVLib.command(arrayOf("seek", (ms / 1000.0).toString(), "absolute"))
            }
            result.success(null)
          } catch (e: Throwable) {
            result.error("SEEK_FAILED", e.message, null)
          }
        }
      }
      "setVolume" -> {
        volume = (call.argument<Number>("volume") ?: 80).toDouble().coerceIn(0.0, 100.0)
        main.post {
          try {
            applyVolumeProperty()
            result.success(null)
          } catch (e: Throwable) {
            result.error("VOLUME_FAILED", e.message, null)
          }
        }
      }
      "setRate" -> {
        rate = (call.argument<Number>("rate") ?: 1).toDouble().coerceIn(0.25, 4.0)
        main.post {
          try {
            if (created.get()) {
              MPVLib.setPropertyDouble("speed", rate)
            }
            result.success(null)
          } catch (e: Throwable) {
            result.error("RATE_FAILED", e.message, null)
          }
        }
      }
      "setRepeatOne" -> {
        repeatOne = call.argument<Boolean>("on") == true
        main.post {
          try {
            if (repeatOne) clearQueuedNext()
            applyRepeatOne()
            result.success(null)
          } catch (e: Throwable) {
            result.error("REPEAT_FAILED", e.message, null)
          }
        }
      }
      "setDecode" -> {
        decodeMode = call.argument<String>("decode") ?: decodeMode
        val props = stringMapArg(call, "props")
        main.post {
          try {
            if (created.get() && createdDirect != wantDirectOutput()) {
              ensurePlayerAndReload(props)
            } else if (created.get()) {
              MPVLib.setPropertyString("hwdec", playerHwdec(decodeMode))
            }
            result.success(null)
          } catch (e: Throwable) {
            result.error("DECODE_FAILED", e.message, null)
          }
        }
      }
      "setRenderMode" -> {
        val mode = call.argument<String>("mode") ?: ""
        main.post {
          try {
            renderTexture = resolveRenderTexture(mode)
            if (surfaceLayerEnabled) {
              surfaceHost?.setRender(renderTexture)
            }
            // 直出只在 Surface 方式下可用，换渲染方式后重新判断。
            if (created.get() && createdDirect != wantDirectOutput()) {
              ensurePlayerAndReload()
            } else if (created.get()) {
              applyDolbyVisionOptions()
            }
            result.success(
              mapOf(
                "ok" to true,
                "render" to if (renderTexture) "texture" else "surface",
                "path" to "platformView",
              ),
            )
          } catch (e: Throwable) {
            result.error("RENDER_FAILED", e.message, null)
          }
        }
      }
      "setSurfaceLayerEnabled" -> {
        val enabled = call.argument<Boolean>("enabled") == true
        main.post {
          try {
            setSurfaceLayerEnabled(enabled)
            result.success(true)
          } catch (e: Throwable) {
            result.error("SURFACE_LAYER_FAILED", e.message, null)
          }
        }
      }
      "setOpts" -> {
        ingestPlayerArgs(call)
        ingestEqualizerArgs(call)
        val props = stringMapArg(call, "props")
        main.post {
          try {
            ensurePlayerAndReload(props)
            result.success(null)
          } catch (e: Throwable) {
            result.error("OPTS_FAILED", e.message, null)
          }
        }
      }
      "setEqualizer" -> {
        ingestEqualizerArgs(call)
        main.post {
          try {
            applyEqualizer()
            result.success(null)
          } catch (e: Throwable) {
            result.error("EQ_FAILED", e.message, null)
          }
        }
      }
      "setProperty" -> {
        val key = call.argument<String>("key") ?: ""
        val value = call.argument<String>("value") ?: ""
        main.post {
          try {
            if (created.get() && key.isNotEmpty()) MPVLib.setPropertyString(key, value)
            result.success(null)
          } catch (e: Throwable) {
            result.error("PROP_FAILED", e.message, null)
          }
        }
      }
      "setAspect" -> {
        val mode = call.argument<String>("mode")?.trim().orEmpty()
        main.post {
          try {
            aspectMode = normalizeAspectMode(mode)
            applyAspectMode()
            applyVideoFrame()
            result.success(true)
          } catch (e: Throwable) {
            result.error("ASPECT_FAILED", e.message, null)
          }
        }
      }
      "setAudioTrack" -> {
        val id = call.argument<String>("id") ?: ""
        main.post {
          try {
            if (created.get()) {
              if (id.isNotEmpty() && id != "auto") {
                MPVLib.command(arrayOf("set", "aid", id))
              } else {
                MPVLib.command(arrayOf("set", "aid", "auto"))
              }
            }
            result.success(null)
          } catch (e: Throwable) {
            result.error("AUDIO_FAILED", e.message, null)
          }
        }
      }
      "getAudioTracks" -> {
        main.post {
          try {
            result.success(buildAudioTracksJson())
          } catch (e: Throwable) {
            result.error("TRACKS_FAILED", e.message, null)
          }
        }
      }
      "videoInfo" -> {
        main.post {
          try {
            result.success(videoInfo())
          } catch (e: Throwable) {
            result.error("VIDEO_INFO_FAILED", e.message, null)
          }
        }
      }
      "getVideoTracks" -> {
        main.post {
          try {
            result.success(buildVideoTracksJson())
          } catch (e: Throwable) {
            result.error("TRACKS_FAILED", e.message, null)
          }
        }
      }
      "getSubtitleTracks" -> {
        main.post {
          try {
            result.success(buildSubtitleTracksJson())
          } catch (e: Throwable) {
            result.error("TRACKS_FAILED", e.message, null)
          }
        }
      }
      "setVideoTrack" -> {
        val id = call.argument<String>("id") ?: ""
        main.post {
          try {
            if (created.get()) {
              if (id.isNotEmpty() && id != "auto") {
                MPVLib.command(arrayOf("set", "vid", id))
              } else {
                MPVLib.command(arrayOf("set", "vid", "auto"))
              }
            }
            result.success(null)
          } catch (e: Throwable) {
            result.error("VIDEO_FAILED", e.message, null)
          }
        }
      }
      "setSubtitleTrack" -> {
        val id = call.argument<String>("id") ?: ""
        main.post {
          try {
            if (created.get()) {
              when {
                id.isEmpty() || id == "no" || id == "off" -> MPVLib.command(arrayOf("set", "sid", "no"))
                id == "auto" -> MPVLib.command(arrayOf("set", "sid", "auto"))
                else -> MPVLib.command(arrayOf("set", "sid", id))
              }
            }
            result.success(null)
          } catch (e: Throwable) {
            result.error("SUB_FAILED", e.message, null)
          }
        }
      }
      "setSecondarySubtitleTrack" -> {
        val id = call.argument<String>("id") ?: "no"
        main.post {
          try {
            if (created.get()) {
              when {
                id.isEmpty() || id == "no" || id == "off" ->
                  MPVLib.command(arrayOf("set", "secondary-sid", "no"))
                id == "auto" ->
                  MPVLib.command(arrayOf("set", "secondary-sid", "auto"))
                else -> MPVLib.command(arrayOf("set", "secondary-sid", id))
              }
            }
            result.success(null)
          } catch (e: Throwable) {
            result.error("SECONDARY_SUB_FAILED", e.message, null)
          }
        }
      }
      "setSubtitleStyle" -> {
        val scale = call.argument<Number>("scale")?.toDouble()
        val pos = call.argument<Number>("pos")?.toDouble()
        val secondaryPos = call.argument<Number>("secondaryPos")?.toDouble()
        val forceStyle = call.argument<Boolean>("forceStyle") == true
        val useSystemStyle = call.argument<Boolean>("useSystemStyle") == true
        val color = call.argument<String>("color")?.trim().orEmpty()
        val borderColor = call.argument<String>("borderColor")?.trim().orEmpty()
        val borderSize = call.argument<Number>("borderSize")?.toDouble()
        val edgeType = call.argument<String>("edgeType")?.trim()?.lowercase().orEmpty()
        val textOpacity = call.argument<Number>("textOpacity")?.toDouble()
        val bgOpacity = call.argument<Number>("bgOpacity")?.toDouble()
        val edgeOpacity = call.argument<Number>("edgeOpacity")?.toDouble()
        val shadowStrength = call.argument<Number>("shadowStrength")?.toDouble()
        val fontName = call.argument<String>("font")?.trim()?.lowercase().orEmpty()
        val fontPath = call.argument<String>("fontPath")?.trim().orEmpty()
        main.post {
          try {
            if (created.get()) {
              if (scale != null) {
                MPVLib.setPropertyDouble("sub-scale", scale.coerceIn(0.5, 2.0))
              }
              if (pos != null) {
                MPVLib.setPropertyDouble("sub-pos", (100.0 - pos).coerceIn(0.0, 150.0))
              }
              if (secondaryPos != null) {
                MPVLib.setPropertyDouble("secondary-sub-pos", secondaryPos.coerceIn(0.0, 150.0))
              }
              val applyLooks = forceStyle || useSystemStyle
              if (applyLooks && color.isNotEmpty()) {
                MPVLib.setPropertyString("sub-color", withOpacity(color, textOpacity))
              }
              if (applyLooks && borderColor.isNotEmpty()) {
                MPVLib.setPropertyString("sub-border-color", withOpacity(borderColor, edgeOpacity))
              }
              if (applyLooks && borderSize != null) {
                MPVLib.setPropertyDouble("sub-border-size", borderSize.coerceIn(0.0, 8.0))
              }
              val bgColor = call.argument<String>("bgColor")?.trim().orEmpty()
              if (applyLooks && bgColor.isNotEmpty()) {
                MPVLib.setPropertyString("sub-back-color", withOpacity(bgColor, bgOpacity))
              }
              if (applyLooks) {
                val strength = ((shadowStrength ?: 50.0).coerceIn(0.0, 100.0) / 50.0).coerceIn(0.0, 2.5)
                when (edgeType) {
                  "none" -> {
                    MPVLib.setPropertyDouble("sub-border-size", 0.0)
                    MPVLib.setPropertyDouble("sub-shadow-offset", 0.0)
                  }
                  "shadow" -> MPVLib.setPropertyDouble("sub-shadow-offset", 2.0 * strength)
                  "raised", "depressed" -> MPVLib.setPropertyDouble("sub-shadow-offset", 1.5 * strength)
                  "outline" -> {
                    if (borderSize == null) {
                      MPVLib.setPropertyDouble("sub-border-size", 2.0)
                    }
                    MPVLib.setPropertyDouble("sub-shadow-offset", 0.0)
                  }
                }
                if (fontPath.isNotEmpty()) {
                  val fontFile = java.io.File(fontPath)
                  val parent = fontFile.parent
                  if (!parent.isNullOrBlank()) {
                    MPVLib.setPropertyString("sub-fonts-dir", parent)
                  }
                  // sub-font 按族名匹配；读不出 name 表再退回文件名。
                  val family = KotvFontFile.familyName(fontFile) ?: fontFile.nameWithoutExtension
                  if (family.isNotBlank()) {
                    MPVLib.setPropertyString("sub-font", family)
                  }
                } else if (fontName.isNotEmpty() && fontName != "default") {
                  val mpvFont =
                    when (fontName) {
                      "sans", "sans-serif" -> "sans-serif"
                      "serif" -> "serif"
                      "mono", "monospace" -> "monospace"
                      else -> fontName
                    }
                  MPVLib.setPropertyString("sub-font", mpvFont)
                }
              }
              MPVLib.setPropertyString(
                "secondary-sub-ass-override",
                if (forceStyle) "force" else "yes",
              )
              MPVLib.setPropertyString("sub-ass-override", if (forceStyle) "force" else "scale")
            }
            result.success(null)
          } catch (e: Throwable) {
            result.error("SUB_STYLE_FAILED", e.message, null)
          }
        }
      }
      "setSubtitleOffsetMs" -> {
        val ms = call.argument<Number>("ms")?.toDouble() ?: 0.0
        main.post {
          try {
            if (created.get()) {
              MPVLib.setPropertyDouble("sub-delay", (ms / 1000.0).coerceIn(-300.0, 300.0))
            }
            result.success(null)
          } catch (e: Throwable) {
            result.error("SUB_OFFSET_FAILED", e.message, null)
          }
        }
      }
      "discTitleCount" -> {
        main.post {
          try {
            val n = if (created.get()) (MPVLib.getPropertyInt("disc-titles") ?: 0) else 0
            result.success(n)
          } catch (e: Throwable) {
            result.error("DISC_FAILED", e.message, null)
          }
        }
      }
      "discChapterCount" -> {
        main.post {
          try {
            val n = if (created.get()) (MPVLib.getPropertyInt("chapters") ?: 0) else 0
            result.success(n)
          } catch (e: Throwable) {
            result.error("DISC_FAILED", e.message, null)
          }
        }
      }
      "setDiscTitle" -> {
        val index = call.argument<Number>("index")?.toInt() ?: 0
        main.post {
          try {
            if (created.get() && index >= 1) {
              MPVLib.setPropertyInt("disc-title", index)
            }
            result.success(null)
          } catch (e: Throwable) {
            result.error("DISC_FAILED", e.message, null)
          }
        }
      }
      "setDiscChapter" -> {
        val index = call.argument<Number>("index")?.toInt() ?: -1
        main.post {
          try {
            if (created.get() && index >= 0) {
              MPVLib.setPropertyInt("chapter", index)
            }
            result.success(null)
          } catch (e: Throwable) {
            result.error("DISC_FAILED", e.message, null)
          }
        }
      }
      "openDiscMenu" -> {
        main.post {
          try {
            if (created.get()) {
              MPVLib.command(arrayOf("discnav", "menu"))
            }
            result.success(null)
          } catch (e: Throwable) {
            result.error("DISC_FAILED", e.message, null)
          }
        }
      }
      "addSubtitle" -> {
        val path = call.argument<String>("path")?.trim().orEmpty()
        val title = call.argument<String>("title")?.trim().orEmpty()
        val select = call.argument<Boolean>("select") != false
        main.post {
          try {
            if (!created.get() || path.isEmpty()) {
              result.error("SUB_FAILED", "empty path or not ready", null)
              return@post
            }
            val flags = if (select) "select" else "auto"
            if (title.isNotEmpty()) {
              MPVLib.command(arrayOf("sub-add", path, flags, title))
            } else {
              MPVLib.command(arrayOf("sub-add", path, flags))
            }
            result.success(true)
          } catch (e: Throwable) {
            result.error("SUB_FAILED", e.message, null)
          }
        }
      }
      "retryVideo" -> {
        main.post {
          try {
            if (created.get()) {
              MPVLib.command(arrayOf("playlist-play-index", "current"))
              unpauseWithAudioFocus()
            }
            result.success(null)
          } catch (e: Throwable) {
            result.error("RETRY_FAILED", e.message, null)
          }
        }
      }
      "dispose" -> {
        main.post {
          destroyPlayer()
          result.success(null)
        }
      }
      else -> result.notImplemented()
    }
  }

  /**
   * 冷选项或输出方式变了就重建上下文（tls、磁盘缓存、直出等在 init 写入），
   * 重建后若有已加载的地址就按进度重载。
   */
  private fun ensurePlayerAndReload(props: Map<String, String> = emptyMap()) {
    val url = loadedUrl
    val headers = if (loadedHeaders.isNotEmpty()) loadedHeaders else pendingHeaders
    val pos = positionSec
    val rebuilt = ensurePlayer()
    applyRuntimeOpts(props)
    applyGpuApiIfNeeded()
    applyDolbyVisionOptions()
    applyPreferredSubtitleLangs()
    applyEqualizer()
    applyAudioDelay()
    applySpdif()
    if (rebuilt && url.isNotBlank()) {
      retrySeekSec = pos.coerceAtLeast(0.0)
      // 与 open 一致：先挂 Surface 再 loadfile，避免有声无画。
      tryAttachSurface()
      if (surfaceLayerEnabled && !surfaceAttached) {
        pendingUrl = url
        pendingHeaders = LinkedHashMap(headers)
        maybeLoadPending()
      } else {
        startLoad(url, headers)
      }
    }
  }

  /** @return true 若因冷选项/模式变更销毁并新建了上下文。 */
  private fun ensurePlayer(): Boolean {
    val ctx = appContext ?: throw IllegalStateException("no context")
    if (!MPVLib.ensureLoaded(ctx)) {
      val err = MPVLib.getLoadError()
      val detail = err?.message ?: "unknown"
      val hint =
        if (detail.contains("vk", ignoreCase = true) || detail.contains("Vulkan", ignoreCase = true)) {
          "Vulkan/load failed (missing Vulkan 1.1 symbols on this device). $detail"
        } else {
          "MPV native load failed: $detail"
        }
      throw IllegalStateException(hint, err)
    }
    var rebuilt = false
    // 点播↔直播 demuxer/cache 选项在 init 时写入；模式变了必须重建上下文。
    val wantLiveBuffer = liveBufferSession()
    if (created.get() && createdAsLive != null && createdAsLive != wantLiveBuffer) {
      Log.i(TAG, "recreate MPV context: liveBuffer $createdAsLive -> $wantLiveBuffer")
      destroyPlayer()
      rebuilt = true
    }
    if (created.get() && createdTlsVerify != null && createdTlsVerify != tlsVerify) {
      Log.i(TAG, "recreate MPV context: tlsVerify $createdTlsVerify -> $tlsVerify")
      destroyPlayer()
      rebuilt = true
    }
    if (created.get() && createdDiskCache != null && createdDiskCache != diskCache) {
      Log.i(TAG, "recreate MPV context: diskCache $createdDiskCache -> $diskCache")
      destroyPlayer()
      rebuilt = true
    }
    if (created.get() && createdBufferBytes != null && createdBufferBytes != bufferBytes) {
      Log.i(TAG, "recreate MPV context: bufferBytes $createdBufferBytes -> $bufferBytes")
      destroyPlayer()
      rebuilt = true
    }
    if (created.get() && createdDirect != null && createdDirect != wantDirectOutput()) {
      Log.i(TAG, "recreate MPV context: direct output $createdDirect -> ${wantDirectOutput()}")
      destroyPlayer()
      rebuilt = true
    }
    if (created.get()) return rebuilt
    synchronized(this) {
      if (created.get()) return rebuilt
      val configDir = File(ctx.filesDir, "mpv").apply { mkdirs() }
      val cacheDir = File(ctx.cacheDir, "mpv").apply { mkdirs() }
      // libass fontconfig 后端从 config-dir/fonts.conf 找系统字体目录与通用族名 alias。
      KotvFontConfig.prepare(configDir, cacheDir)
      if (!MPVLib.tryCreate(ctx)) {
        // 已有上下文：先销毁再试一次
        MPVLib.destroyCreatedContext()
        if (!MPVLib.tryCreate(ctx)) {
          throw IllegalStateException("MPV create failed")
        }
      }
      MPVLib.setOptionString("config", "yes")
      MPVLib.setOptionString("config-dir", configDir.absolutePath)
      MPVLib.setOptionString("gpu-shader-cache-dir", cacheDir.absolutePath)
      MPVLib.setOptionString("icc-cache-dir", cacheDir.absolutePath)
      val direct = wantDirectOutput()
      createdDirect = direct
      MPVLib.setOptionString("hwdec", playerHwdec(decodeMode))
      if (direct) {
        // 直出只能显示 MediaCodec 解出的帧：所有编码都先交给 MediaCodec。
        MPVLib.setOptionString("hwdec-codecs", "all")
      }
      if (isRockchip()) {
        MPVLib.setOptionString("vd-lavc-dr", "no")
      }
      MPVLib.setOptionString("vo", videoOutput())
      applyGpuApiOptions()
      // 默认 cacert 校验；坏 CA 可关。
      applyTlsOptions(ctx)
      // https→http、以及 HLS 分片伪装成 .png/.jpg：须放行扩展名。
      // 不设 protocol_whitelist，避免挡掉 RTSP/RTMP/RTP。
      // FFmpeg 9 默认 extension_picky=1，只认常见后缀；点播常首片 .ts、后面 .png（内容仍是 TS）。
      MPVLib.setOptionString("demuxer-lavf-o", KotvAndroidPlayback.LAVF_DEMUXER_O)
      // 不按后缀当播放列表/图片（.m3u8 可能是 FLV，.png 可能是 TS）；lavf 按内容探测。
      MPVLib.setOptionString("playlist-exts", "")
      MPVLib.setOptionString("image-exts", "")
      // ytdl_hook aborts load on devices without youtube-dl; disable.
      MPVLib.setOptionString("ytdl", "no")
      val liveBuf = liveBufferSession()
      if (liveBuf) {
        MPVLib.setOptionString("cache-pause", "no")
      }
      // Do not force gpu-api=vulkan on API 25: GLES path for picture;
      // libvulkan.so is only to satisfy libmpv DT_NEEDED.
      MPVLib.setOptionString("force-window", "no")
      MPVLib.setOptionString("idle", "yes")
      // 默认 yes：无排队时末项 eof-reached→completed；有排队时 queueNext 改为 no（见 applyKeepOpenForQueue）。
      MPVLib.setOptionString("keep-open", "yes")
      // 预加载下一集：本集将完时提前打开排在后面的一项。
      MPVLib.setOptionString("prefetch-playlist", "yes")
      MPVLib.setOptionString("loop-file", loopFile())
      if (!liveBuf) {
        if (diskCache) {
          val dir = File(ctx.cacheDir, "mpv-cache").apply { mkdirs() }
          MPVLib.setOptionString("cache-on-disk", "yes")
          MPVLib.setOptionString("demuxer-cache-dir", dir.absolutePath)
        } else {
          MPVLib.setOptionString("cache-on-disk", "no")
        }
      }
      val spdif = spdifCodecs(ctx)
      MPVLib.setOptionString("audio-spdif", spdif)
      appliedSpdif = spdif
      Log.i(TAG, "audio-spdif=$spdif")
      applyDolbyVisionOptions()
      applyPreferredSubtitleLangs()
      // 字幕基础：内嵌字体 + ASS 按比例缩放（细项仍可走 mpv.conf / setSubtitleStyle）。
      MPVLib.setOptionString("embeddedfonts", "yes")
      MPVLib.setOptionString("sub-ass-override", "scale")
      MPVLib.setOptionString("sub-scale", "1.0")
      MPVLib.setOptionString("sub-scale-signs", "yes")
      MPVLib.setOptionString("secondary-sub-ass-override", "yes")
      MPVLib.setOptionString("secondary-sid", "no")
      for ((k, v) in KotvAndroidPlayback.mpvDemuxerByteProps(bufferBytes)) {
        MPVLib.setOptionString(k, v)
      }
      applyConfOptions(conf)
      MPVLib.init()
      MPVLib.setOptionString("force-window", "no")
      MPVLib.addObserver(this)
      observeProps()
      created.set(true)
      createdAsLive = liveBufferSession()
      createdTlsVerify = tlsVerify
      createdDiskCache = diskCache
      createdBufferBytes = bufferBytes
      applyAspectMode()
      applyAudioDelay()
      main.removeCallbacks(tick)
      main.post(tick)
      Log.i(
        TAG,
        "MPV context ready abi=${MPVLib.getLoadedAbi()} live=$livePlayback engineLive=$engineLive tlsVerify=$tlsVerify",
      )
    }
    return rebuilt
  }

  /** 标定直播或引擎 media-live：关 cache-pause / 磁盘缓存。 */
  private fun liveBufferSession(): Boolean = livePlayback || engineLive

  /** 从 assets 拷 cacert.pem，设 tls-ca-file；关闭校验时 tls-verify=no。 */
  private fun applyTlsOptions(ctx: Context) {
    if (!tlsVerify) {
      MPVLib.setOptionString("tls-verify", "no")
      return
    }
    val ca = ensureCacertFile(ctx)
    if (ca != null) {
      MPVLib.setOptionString("tls-ca-file", ca.absolutePath)
      MPVLib.setOptionString("tls-verify", "yes")
    } else {
      Log.w(TAG, "cacert.pem missing → tls-verify=no")
      MPVLib.setOptionString("tls-verify", "no")
    }
  }

  private fun ensureCacertFile(ctx: Context): File? {
    return try {
      val out = File(ctx.filesDir, "cacert.pem")
      if (!out.exists() || out.length() < 1024) {
        ctx.assets.open("cacert.pem").use { input ->
          out.outputStream().use { output -> input.copyTo(output) }
        }
      }
      if (out.exists() && out.length() > 1024) out else null
    } catch (t: Throwable) {
      Log.w(TAG, "ensure cacert failed", t)
      null
    }
  }

  /** 设备 Vulkan≥1.2 且用户开启：gpu-api=vulkan + gpu-context=androidvk；否则 opengl + android。 */
  private fun applyGpuApiOptions() {
    val ctx = appContext
    val useVulkan =
      vulkanEnabled && ctx != null && MPVLib.isVulkanRendererAvailable(ctx)
    if (useVulkan) {
      MPVLib.setOptionString("gpu-api", "vulkan")
      MPVLib.setOptionString("gpu-context", "androidvk")
    } else {
      MPVLib.setOptionString("gpu-api", "opengl")
      MPVLib.setOptionString("gpu-context", "android")
      MPVLib.setOptionString("opengl-es", "yes")
    }
  }

  private fun applyGpuApiIfNeeded() {
    if (!created.get()) return
    val ctx = appContext ?: return
    val useVulkan = vulkanEnabled && MPVLib.isVulkanRendererAvailable(ctx)
    try {
      if (useVulkan) {
        MPVLib.setPropertyString("gpu-api", "vulkan")
        MPVLib.setPropertyString("gpu-context", "androidvk")
      } else {
        MPVLib.setPropertyString("gpu-api", "opengl")
        MPVLib.setPropertyString("gpu-context", "android")
        MPVLib.setPropertyString("opengl-es", "yes")
      }
    } catch (_: Throwable) {
    }
  }

  /**
   * 杜比视界输出。direct：遇到杜比视界轨道时 libmpv 自己换成 mediacodec_embed，
   * 由 MediaCodec 直接把画面送到 Surface，电视才进杜比视界模式；换不成会退回普通渲染。
   * 直出要 SurfaceView 和非拷贝硬解，Texture 方式或软解一律 configured。
   */
  private fun applyDolbyVisionOptions() {
    val ctx = appContext
    val displayDv = ctx != null && KotvDisplayHdr.supportsDolbyVision(ctx)
    val wantDirect = when (dolbyVisionPolicy) {
      1 -> true
      2 -> false
      else -> displayDv
    }
    val direct = wantDirect && !renderTexture && resolveHwdec(decodeMode) != "no"
    // 显示器不支持杜比视界时，双层 Profile 7 只留 HDR10 基础层；用户选「开」则保留原样。
    val profile7 = if (!displayDv && dolbyVisionPolicy != 1) "hdr10" else "preserve"
    setMpvOption("android-dolby-vision-output", if (direct) "direct" else "configured")
    setMpvOption("demuxer-dovi-profile7", profile7)
    dvDirect = direct
    surfaceHost?.setOsdLayer(osdWanted())
    syncOsdSurface()
  }

  /** 直出（硬解直出或杜比视界直出）时画面不经 mpv 渲染，字幕要叠层 OSD Surface。 */
  private fun osdWanted(): Boolean = dvDirect || createdDirect == true

  /** 直出时画面不经 mpv 渲染，字幕画在叠在视频上方的透明 OSD Surface 上；须在视频 Surface 之后挂。 */
  private fun syncOsdSurface() {
    val target = if (osdWanted() && created.get() && surfaceAttached) {
      surfaceHost?.currentOsdSurface()
    } else {
      null
    }
    if (target !== attachedOsdSurface) {
      detachOsdSurface()
      if (target == null) return
      try {
        MPVLib.attachOsdSurface(target)
        attachedOsdSurface = target
      } catch (t: Throwable) {
        Log.w(TAG, "attachOsdSurface", t)
        return
      }
    }
    if (target != null) applyOsdSurfaceSize(surfaceHost?.osdSize)
  }

  /** OSD 层随视频画框缩放，尺寸变了要告诉 mpv（android-osd-surface-size）。 */
  private fun applyOsdSurfaceSize(size: String?) {
    if (size == null || size == appliedOsdSize) return
    try {
      MPVLib.setPropertyString("android-osd-surface-size", size)
      appliedOsdSize = size
    } catch (t: Throwable) {
      Log.w(TAG, "android-osd-surface-size", t)
    }
  }

  private fun detachOsdSurface() {
    appliedOsdSize = null
    if (attachedOsdSurface == null) return
    attachedOsdSurface = null
    if (!created.get()) return
    try {
      MPVLib.detachOsdSurface()
    } catch (t: Throwable) {
      Log.w(TAG, "detachOsdSurface", t)
    }
  }

  /** 播放信息：hwdec-current、片源色彩、是否杜比视界直出、显示器 HDR 能力。 */
  private fun videoInfo(): Map<String, String> {
    val display = appContext?.let { KotvDisplayHdr.label(it) } ?: ""
    if (!created.get()) return mapOf("display" to display)
    fun prop(name: String) = MPVLib.getPropertyString(name)?.trim().orEmpty()
    val dvProfile = prop("current-tracks/video/dolby-vision-profile")
    var transfer = when (prop("video-params/gamma")) {
      "" -> ""
      "pq" -> "PQ"
      "hlg" -> "HLG"
      else -> "SDR"
    }
    var primaries = prop("video-params/primaries").uppercase()
    // gamma 缺省但有杜比 profile：补 PQ/BT.2020，避免误标纯 SDR。
    if (dvProfile.isNotEmpty()) {
      if (transfer.isEmpty() || transfer == "SDR") transfer = "PQ"
      if (primaries.isEmpty() || primaries == "BT.709") primaries = "BT.2020"
    }
    if (transfer.isEmpty()) transfer = "SDR"
    return mapOf(
      "hwdec" to prop("hwdec-current"),
      "transfer" to transfer,
      "primaries" to primaries,
      "dolbyVision" to if (dvProfile.isEmpty()) "" else "杜比视界 P$dvProfile",
      "output" to when {
        prop("current-vo") != "mediacodec_embed" -> ""
        dvProfile.isNotEmpty() -> "杜比视界直出"
        else -> "直出"
      },
      "display" to display,
    )
  }

  /** 上下文建好前写 option，之后写 property；libmpv 不认的取值只返回错误码，这里记下来。 */
  private fun setMpvOption(name: String, value: String) {
    try {
      val code = if (created.get()) {
        MPVLib.setPropertyString(name, value)
      } else {
        MPVLib.setOptionString(name, value)
      }
      if (code < 0) Log.w(TAG, "mpv $name=$value rejected ($code)")
    } catch (t: Throwable) {
      Log.w(TAG, "mpv $name=$value", t)
    }
  }

  private fun applyPreferredSubtitleLangs() {
    val langs = preferredTextLangs.trim().ifEmpty {
      KotvLangUtil.preferredTextLanguages().joinToString(",")
    }
    if (langs.isEmpty()) return
    try {
      val normalized = langs.replace(';', ',').replace(Regex("\\s+"), "")
      if (created.get()) {
        MPVLib.setPropertyString("slang", normalized)
      } else {
        MPVLib.setOptionString("slang", normalized)
      }
    } catch (t: Throwable) {
      Log.w(TAG, "slang", t)
    }
  }

  /** 音轨列表（含 AV3A 等 FFmpeg/libarcdav3a 解码轨）。 */
  private fun buildAudioTracksJson(): String {
    return buildTracksJson("audio")
  }

  /** 视频轨列表。 */
  private fun buildVideoTracksJson(): String {
    return buildTracksJson("video")
  }

  /** 字幕轨列表（内嵌 sub）。 */
  private fun buildSubtitleTracksJson(): String {
    return buildTracksJson("sub")
  }

  private fun buildTracksJson(typeFilter: String): String {
    if (!created.get()) return "[]"
    val count = MPVLib.getPropertyInt("track-list/count") ?: 0
    val arr = JSONArray()
    for (i in 0 until count) {
      val type = MPVLib.getPropertyString("track-list/$i/type") ?: continue
      if (type != typeFilter) continue
      val obj = JSONObject()
      obj.put("id", MPVLib.getPropertyString("track-list/$i/id") ?: "auto")
      obj.put("title", MPVLib.getPropertyString("track-list/$i/title") ?: "")
      obj.put("lang", MPVLib.getPropertyString("track-list/$i/lang") ?: "")
      obj.put("codec", MPVLib.getPropertyString("track-list/$i/codec") ?: "")
      val w = MPVLib.getPropertyInt("track-list/$i/demux-w") ?: 0
      val h = MPVLib.getPropertyInt("track-list/$i/demux-h") ?: 0
      if (w > 0 && h > 0) {
        obj.put("width", w)
        obj.put("height", h)
      }
      arr.put(obj)
    }
    return arr.toString()
  }

  /** Rockchip 芯片（RK3399、RK3588 等）。 */
  private fun isRockchip(): Boolean {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
      Build.SOC_MANUFACTURER.equals("Rockchip", ignoreCase = true)
    ) {
      return true
    }
    val hw = (Build.HARDWARE ?: "").lowercase()
    return hw.startsWith("rk") ||
      listOf(Build.BOARD, Build.PRODUCT, Build.MODEL).any { (it ?: "").lowercase().contains("rk3") } ||
      (Build.MODEL ?: "").lowercase().contains("cr19")
  }

  /**
   * 硬解直出：MediaCodec 把画面直接交给 SurfaceView，由系统合成输出（HDR 也由系统送显），
   * 不经 mpv 的 GL 渲染（vo=mediacodec_embed）。
   * - Android 8.0 以下没有 AImageReader，GL 渲染拿不到硬解画面，硬解只能直出；
   * - Rockchip 盒子默认直出。
   * 要求 SurfaceView 和硬解；字幕画在叠层 OSD Surface 上，滤镜、着色器等 GL 处理不生效。
   */
  private fun wantDirectOutput(): Boolean =
    !renderTexture && resolveHwdec(decodeMode) != "no" &&
      (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || isRockchip())

  /** 当前上下文的 vo。 */
  private fun videoOutput(): String = when {
    createdDirect == true -> "mediacodec_embed"
    gpuNext -> "gpu-next"
    else -> "gpu"
  }

  /** 交给 mpv 的 hwdec：直出固定 mediacodec，否则按解码设置。 */
  private fun playerHwdec(raw: String?): String =
    if (createdDirect == true) "mediacodec" else resolveHwdec(raw)

  /**
   * 解码设置 → GL 渲染用的 hwdec。8.0 以上 mediacodec 经 AImageReader 零拷贝；
   * 以下只能 mediacodec-copy（拷回内存再上传）。自动 = 硬解优先、失败软解。
   */
  private fun resolveHwdec(raw: String?): String {
    val mode = raw?.trim().orEmpty()
    if (mode == "no" || mode == "soft" || mode == "software" || mode == "sw") return "no"
    // 已是逗号列表（如 mediacodec,no）原样交给 mpv。
    if (mode.contains(",")) return mode
    val hw = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) "mediacodec" else "mediacodec-copy"
    return when (mode) {
      "mediacodec", "hard", "hardware", "hw" -> hw
      "", "auto", "auto-safe" -> "$hw,no"
      else -> mode
    }
  }

  private fun applyConfOptions(text: String) {
    for (raw in text.split(Regex("[\r\n]+"))) {
      var line = raw.trim()
      if (line.isEmpty() || line.startsWith("#")) continue
      val hash = line.indexOf('#')
      if (hash > 0) line = line.substring(0, hash).trim()
      if (line.isEmpty()) continue
      val key: String
      val value: String
      val eq = line.indexOf('=')
      if (eq > 0) {
        key = line.substring(0, eq).trim()
        value = line.substring(eq + 1).trim()
      } else {
        val sp = Regex("\\s+").find(line) ?: continue
        key = line.substring(0, sp.range.first).trim()
        value = line.substring(sp.range.last + 1).trim()
      }
      if (key.isEmpty()) continue
      // `kotv-*` 是应用自用开关，不是 mpv 选项。
      if (key.startsWith("kotv-")) continue
      val base = if (key.startsWith("no-")) key.substring(3) else key
      if (MANAGED_CONF_OPTIONS.contains(key) || MANAGED_CONF_OPTIONS.contains(base)) {
        Log.i(TAG, "skip conf option managed by UI/engine: $key")
        continue
      }
      try {
        MPVLib.setOptionString(key, value.ifEmpty { "yes" })
      } catch (_: Throwable) {
      }
    }
  }

  /** 通道参数里的字典（headers / props）转成字符串表；没传为空表。 */
  private fun stringMapArg(call: MethodCall, key: String): Map<String, String> =
    (call.argument<Map<*, *>>(key) ?: emptyMap<Any, Any>()).entries.associate { "${it.key}" to "${it.value}" }

  /** 通道参数里的 map 列表（如 queueNext.subs）；元素非 map 则跳过。 */
  private fun listMapArg(call: MethodCall, key: String): List<Map<String, Any?>> {
    val raw = call.argument<List<*>>(key) ?: return emptyList()
    val out = ArrayList<Map<String, Any?>>(raw.size)
    for (item in raw) {
      val m = item as? Map<*, *> ?: continue
      out.add(m.entries.associate { "${it.key}" to it.value })
    }
    return out
  }

  private fun ingestPlayerArgs(call: MethodCall) {
    decodeMode = call.argument<String>("decode") ?: decodeMode
    gpuNext = call.argument<Boolean>("gpuNext") == true
    vulkanEnabled = call.argument<Boolean>("vulkan") == true
    conf = call.argument<String>("conf") ?: conf
    call.argument<Boolean>("tlsVerify")?.let { tlsVerify = it }
    call.argument<Boolean>("audioPassThrough")?.let { audioPassThrough = it }
    call.argument<Boolean>("diskCache")?.let { diskCache = it }
    call.argument<Number>("dolbyVisionPolicy")?.toInt()?.let { dolbyVisionPolicy = it }
    call.argument<String>("preferredTextLangs")?.let { preferredTextLangs = it.trim() }
    call.argument<Number>("bufferBytes")?.toLong()?.let { n ->
      bufferBytes =
        if (n > 0L) n.coerceAtMost(Int.MAX_VALUE.toLong()).toInt() else 0
    }
    call.argument<Number>("audioOffsetMs")?.toDouble()?.let { ms ->
      audioDelaySec = (ms / 1000.0).coerceIn(-10.0, 10.0)
    }
  }

  private fun applyAudioDelay() {
    if (!created.get()) return
    try {
      MPVLib.setPropertyDouble("audio-delay", audioDelaySec)
    } catch (t: Throwable) {
      Log.w(TAG, "audio-delay", t)
    }
  }

  private fun ingestEqualizerArgs(call: MethodCall) {
    call.argument<Number>("eqBrightness")?.toInt()?.let { eqBrightness = it.coerceIn(-100, 100) }
    call.argument<Number>("eqContrast")?.toInt()?.let { eqContrast = it.coerceIn(-100, 100) }
    call.argument<Number>("eqSaturation")?.toInt()?.let { eqSaturation = it.coerceIn(-100, 100) }
    call.argument<Number>("eqGamma")?.toInt()?.let { eqGamma = it.coerceIn(-100, 100) }
    call.argument<Number>("eqHue")?.toInt()?.let { eqHue = it.coerceIn(-100, 100) }
    call.argument<String>("audioAf")?.let { audioAf = it.trim() }
    call.argument<String>("videoVf")?.let { videoVf = it.trim() }
    call.argument<Number>("subtitleFontScale")?.toDouble()?.let {
      try {
        MPVLib.setPropertyDouble("sub-scale", it.coerceIn(0.5, 2.0))
      } catch (_: Throwable) {
      }
    }
  }

  private fun applyEqualizer() {
    if (!created.get()) return
    try {
      MPVLib.setPropertyInt("brightness", eqBrightness)
      MPVLib.setPropertyInt("contrast", eqContrast)
      MPVLib.setPropertyInt("saturation", eqSaturation)
      MPVLib.setPropertyInt("gamma", eqGamma)
      MPVLib.setPropertyInt("hue", eqHue)
    } catch (t: Throwable) {
      Log.w(TAG, "apply video eq", t)
    }
    try {
      // mediacodec_embed 直出时画面不经 mpv 滤镜链；锐度 vf 无效且宜清空。
      val vf = if (directActive) "" else videoVf
      MPVLib.setPropertyString("vf", vf)
    } catch (t: Throwable) {
      Log.w(TAG, "apply video vf", t)
    }
    applyAudioAf()
  }

  private fun applyAudioAf() {
    try {
      // 直通时不强塞 af，避免破 SPDIF。
      if (!appliedSpdif.isNullOrEmpty() && audioAf.isNotEmpty()) {
        Log.i(TAG, "skip audio af while passthrough enabled")
      } else {
        MPVLib.setPropertyString("af", audioAf)
      }
    } catch (t: Throwable) {
      Log.w(TAG, "apply audio af", t)
    }
  }

  /** 设置开且当前输出能直出时才直通；手机扬声器等不支持时 MPV 直接解成 PCM。 */
  private fun spdifCodecs(ctx: Context?): String {
    if (!audioPassThrough || ctx == null) return ""
    val candidates = listOf(
      "ac3" to AudioFormat.ENCODING_AC3,
      "eac3" to AudioFormat.ENCODING_E_AC3,
      "truehd" to AudioFormat.ENCODING_DOLBY_TRUEHD,
      "dts" to AudioFormat.ENCODING_DTS,
      "dtshd" to AudioFormat.ENCODING_DTS_HD,
    )
    val supported = try {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        val attrs = AudioAttributes.Builder()
          .setUsage(AudioAttributes.USAGE_MEDIA)
          .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
          .build()
        val masks = intArrayOf(AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.CHANNEL_OUT_7POINT1_SURROUND)
        candidates.filter { (_, enc) ->
          masks.any { mask ->
            val fmt = AudioFormat.Builder()
              .setEncoding(enc)
              .setSampleRate(48000)
              .setChannelMask(mask)
              .build()
            AudioTrack.isDirectPlaybackSupported(fmt, attrs)
          }
        }
      } else {
        val encodings = HashSet<Int>()
        val plug = ctx.registerReceiver(null, IntentFilter(AudioManager.ACTION_HDMI_AUDIO_PLUG))
        if (plug != null && plug.getIntExtra(AudioManager.EXTRA_AUDIO_PLUG_STATE, 0) == 1) {
          plug.getIntArrayExtra(AudioManager.EXTRA_ENCODINGS)?.forEach { encodings.add(it) }
        }
        val am = ctx.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        am?.getDevices(AudioManager.GET_DEVICES_OUTPUTS)?.forEach { dev ->
          when (dev.type) {
            AudioDeviceInfo.TYPE_HDMI, AudioDeviceInfo.TYPE_HDMI_ARC, AudioDeviceInfo.TYPE_LINE_DIGITAL ->
              dev.encodings.forEach { encodings.add(it) }
          }
        }
        candidates.filter { (_, enc) -> enc in encodings }
      }
    } catch (t: Throwable) {
      Log.w(TAG, "query passthrough support", t)
      emptyList()
    }
    return supported.joinToString(",") { it.first }
  }

  /** 每次 loadfile 前按当前输出设备重算（插拔 HDMI 后下一次起播生效）。 */
  private fun applySpdif() {
    val spdif = spdifCodecs(appContext)
    if (spdif == appliedSpdif) return
    try {
      MPVLib.setPropertyString("audio-spdif", spdif)
      appliedSpdif = spdif
      Log.i(TAG, "audio-spdif=$spdif")
      applyAudioAf()
    } catch (t: Throwable) {
      Log.w(TAG, "apply audio-spdif", t)
    }
  }

  private fun applyRuntimeOpts(props: Map<String, String>) {
    if (!created.get()) return
    try {
      MPVLib.setPropertyString("hwdec", playerHwdec(props["hwdec"] ?: decodeMode))
    } catch (_: Throwable) {
    }
    if (surfaceReady) {
      try {
        MPVLib.setPropertyString("vo", videoOutput())
      } catch (_: Throwable) {
      }
    }
    for ((k, v) in props) {
      // cache-on-disk / demuxer-cache-dir 由 ensurePlayer(diskCache) 独占，勿被 props 盖掉。
      if (k == "hwdec" || k == "vo" || k == "wid" || k == "android-surface-size" ||
        k == "cache-on-disk" || k == "demuxer-cache-dir"
      ) continue
      try {
        MPVLib.setPropertyString(k, v)
      } catch (_: Throwable) {
      }
    }
  }

  private fun normalizeAspectMode(raw: String): String {
    return when (raw.trim().lowercase()) {
      "fill", "stretch" -> "fill"
      "zoom", "cover", "crop" -> "zoom"
      "16:9", "16/9" -> "16:9"
      "4:3", "4/3" -> "4:3"
      else -> "default"
    }
  }

  /**
   * 画面比例（适应·拉伸·Zoom·16:9·4:3）：
   * - 适应：keepaspect，不裁切
   * - 拉伸：铺满窗口（可变形）
   * - Zoom：keepaspect + panscan 裁切铺满
   * - 16:9 / 4:3：强制片源画幅（如 4:3 片源选 16:9 会横向拉满）
   */
  /**
   * 直出时 mpv 不缩放画面，MediaCodec 会把画面拉满 Surface：按比例设置摆放视频 SurfaceView。
   * GL 渲染时由 mpv 自己处理比例，SurfaceView 铺满。
   */
  private fun applyVideoFrame() {
    val aspect = when {
      !directActive -> 0.0
      aspectMode == "16:9" -> 16.0 / 9.0
      aspectMode == "4:3" -> 4.0 / 3.0
      else -> videoAspect
    }
    surfaceHost?.setVideoFrame(aspect, aspectMode)
  }

  private fun applyAspectMode() {
    if (!created.get()) return
    try {
      when (aspectMode) {
        "fill" -> {
          MPVLib.setPropertyBoolean("keepaspect", false)
          MPVLib.setPropertyDouble("panscan", 0.0)
          MPVLib.setPropertyString("video-aspect-override", "no")
        }
        "zoom" -> {
          MPVLib.setPropertyBoolean("keepaspect", true)
          MPVLib.setPropertyDouble("panscan", 1.0)
          MPVLib.setPropertyString("video-aspect-override", "no")
        }
        "16:9" -> {
          MPVLib.setPropertyBoolean("keepaspect", true)
          MPVLib.setPropertyDouble("panscan", 0.0)
          MPVLib.setPropertyString("video-aspect-override", "16:9")
        }
        "4:3" -> {
          MPVLib.setPropertyBoolean("keepaspect", true)
          MPVLib.setPropertyDouble("panscan", 0.0)
          MPVLib.setPropertyString("video-aspect-override", "4:3")
        }
        else -> {
          MPVLib.setPropertyBoolean("keepaspect", true)
          MPVLib.setPropertyDouble("panscan", 0.0)
          MPVLib.setPropertyString("video-aspect-override", "no")
        }
      }
    } catch (e: Throwable) {
      Log.w(TAG, "applyAspectMode $aspectMode", e)
    }
  }

  private fun observeProps() {
    MPVLib.observeProperty("time-pos", MPVLib.MpvFormat.MPV_FORMAT_DOUBLE)
    MPVLib.observeProperty("duration", MPVLib.MpvFormat.MPV_FORMAT_DOUBLE)
    MPVLib.observeProperty("duration/full", MPVLib.MpvFormat.MPV_FORMAT_DOUBLE)
    // mpv 语义为 flag；桌面 media_kit 只能订 string，此处订 FLAG 即可。
    MPVLib.observeProperty("media-live", MPVLib.MpvFormat.MPV_FORMAT_FLAG)
    MPVLib.observeProperty("pause", MPVLib.MpvFormat.MPV_FORMAT_FLAG)
    MPVLib.observeProperty("paused-for-cache", MPVLib.MpvFormat.MPV_FORMAT_FLAG)
    MPVLib.observeProperty("seeking", MPVLib.MpvFormat.MPV_FORMAT_FLAG)
    MPVLib.observeProperty("eof-reached", MPVLib.MpvFormat.MPV_FORMAT_FLAG)
    MPVLib.observeProperty("playlist-pos", MPVLib.MpvFormat.MPV_FORMAT_INT64)
    MPVLib.observeProperty("width", MPVLib.MpvFormat.MPV_FORMAT_INT64)
    MPVLib.observeProperty("height", MPVLib.MpvFormat.MPV_FORMAT_INT64)
    MPVLib.observeProperty("video-params/w", MPVLib.MpvFormat.MPV_FORMAT_INT64)
    MPVLib.observeProperty("video-params/h", MPVLib.MpvFormat.MPV_FORMAT_INT64)
    MPVLib.observeProperty("video-params/aspect", MPVLib.MpvFormat.MPV_FORMAT_DOUBLE)
    MPVLib.observeProperty("current-vo", MPVLib.MpvFormat.MPV_FORMAT_STRING)
  }

  private fun effectiveDurationSec(): Double =
    when {
      durationFullSec > 0.0 -> durationFullSec
      durationSec > 0.0 -> durationSec
      else -> 0.0
    }

  private fun resolveRenderTexture(mode: String): Boolean {
    val m = mode.trim().lowercase()
    return m == "texture" || m == "textureview" || m == "1"
  }

  /**
   * 绑定视频输出：
   * - 同一 Surface：只更新 android-surface-size
   * - 新 Surface：attach + 设 vo，不 loadfile / 不 playlist-play-index
   */
  private fun tryAttachSurface() {
    if (!surfaceLayerEnabled || !created.get()) return
    val surface = surfaceHost?.currentSurface() ?: return
    if (!surface.isValid) return
    try {
      val size = surfaceSizeOf(surfaceHost)
      if (surfaceAttached && attachedSurface === surface) {
        if (size != null) applySurfaceSize(size)
        return
      }
      if (surfaceAttached) {
        try {
          MPVLib.detachSurface()
        } catch (_: Throwable) {
        }
        surfaceAttached = false
        attachedSurface = null
      }
      MPVLib.attachSurface(surface)
      surfaceAttached = true
      attachedSurface = surface
      appliedSurfaceSize = null
      if (size != null) applySurfaceSize(size)
      MPVLib.setPropertyString("vo", videoOutput())
      syncOsdSurface()
      // 绑定输出时不强制 force-window / 不重播；保持 pause 与 time-pos。
      if (pendingUrl == null) {
        MPVLib.setPropertyBoolean("pause", paused)
      }
    } catch (e: Throwable) {
      Log.e(TAG, "attachSurface", e)
    }
  }

  /** 优先缓冲区回调的宽高，没有时退回 View 宽高。 */
  private fun surfaceSizeOf(host: KotvMpvSurfaceHost?): String? {
    if (host == null) return null
    host.bufferSize?.let { return it }
    val w = host.width
    val h = host.height
    return if (w > 0 && h > 0) "${w}x${h}" else null
  }

  /** android-surface-size 唯一写入处；未绑 Surface 时由 tryAttachSurface 绑定后再写。 */
  private fun applySurfaceSize(size: String) {
    if (!created.get() || !surfaceAttached || size == appliedSurfaceSize) return
    try {
      MPVLib.setPropertyString("android-surface-size", size)
      appliedSurfaceSize = size
    } catch (t: Throwable) {
      Log.w(TAG, "android-surface-size", t)
    }
  }

  private fun maybeLoadPending() {
    val url = pendingUrl ?: return
    if (!created.get()) return
    tryAttachSurface()
    // Surface 模式必须先挂上 wid；未就绪则保留 pending，等 onSurface/setSurfaceLayer。
    if (surfaceLayerEnabled && !surfaceAttached) return
    pendingUrl = null
    val headers = LinkedHashMap(pendingHeaders)
    loadGen.incrementAndGet()
    startLoad(url, headers)
  }

  private fun startLoad(url: String, headers: Map<String, String>) {
    try {
      queuedNext = null
      pendingSeamlessId = null
      loadedUrl = url
      loadedHeaders = KotvPlayerNormalize.normalizeHeaders(headers)
      applySpdif()
      applyVolumeProperty()
      MPVLib.setPropertyDouble("speed", rate)
      val startMs = pendingStartAtMs
      pendingStartAtMs = 0L
      maxPlayedSec = 0.0
      durationFullSec = 0.0
      upgradedLiveFromMedia = livePlayback || engineLive
      loadWallMs = SystemClock.elapsedRealtime()
      // lavf / headers / start 只挂在这一次 loadfile 上，播完恢复。
      loadfile(url, "replace", buildLoadfileOpts(url, currentMime, headers, startMs))
      unpauseWithAudioFocus()
      buffering = true
      eof = false
    } catch (e: Throwable) {
      emit(mapOf("event" to "error", "message" to (e.message ?: "load failed")))
    }
  }

  /**
   * 把下一集追加到 mpv 播放列表（请求头、片头 start 只写在这一项上）；prefetch-playlist 让 mpv
   * 在本集将完时就打开它。成功后 keep-open=no，EOF 自然前进（契约与 Dart KotvPlayback.queueNext 一致）。
   */
  private fun queueNext(next: KotvQueuedNext): Boolean {
    if (!created.get() || livePlayback || next.id.isEmpty() || next.url.isEmpty() || loadedUrl.isEmpty() || repeatOne) {
      return false
    }
    // 请求头与当前集不同则不排（http-header-fields 是播放器级共用）。
    val curHeaders = KotvPlayerNormalize.normalizeHeaders(loadedHeaders)
    if (next.headers != curHeaders) {
      clearQueuedNext()
      return false
    }
    return try {
      // 只留正在播的一项，新排的总在第 2 项（下标 1）。
      MPVLib.command(arrayOf("playlist-clear"))
      loadfile(
        next.url,
        "append",
        buildLoadfileOpts(next.url, next.mime, next.headers, next.startAtMs),
      )
      queuedNext = next
      applyKeepOpenForQueue(hasQueued = true)
      true
    } catch (t: Throwable) {
      Log.w(TAG, "queue next failed", t)
      false
    }
  }

  /** loadfile 一次性选项：start + HLS lavf + 请求头。 */
  private fun buildLoadfileOpts(
    url: String,
    mime: String?,
    headers: Map<String, String>,
    startAtMs: Long,
  ): List<String> {
    val opts = ArrayList<String>(8)
    if (startAtMs > 0L) opts.add("start=${startAtMs / 1000.0}")
    KotvAndroidPlayback.appendLavfHlsLoadOpts(url, mime, opts)
    appendHeaderOptions(headers, opts)
    return opts
  }

  private fun loadfile(url: String, mode: String, opts: List<String>) {
    if (opts.isEmpty()) {
      MPVLib.command(arrayOf("loadfile", url, mode))
    } else {
      MPVLib.command(arrayOf("loadfile", url, mode, "-1", encodeLoadfileOptions(opts)))
    }
  }

  /**
   * 有排队 → keep-open=no（列表自然前进）；否则 → yes（末项 eof-reached→completed）。
   * 与桌面 media_kit 同一契约（见 Dart KotvPlayback.queueNext）。
   */
  private fun applyKeepOpenForQueue(hasQueued: Boolean) {
    if (!created.get()) return
    try {
      MPVLib.setPropertyString("keep-open", if (hasQueued) "no" else "yes")
    } catch (t: Throwable) {
      Log.w(TAG, "keep-open", t)
    }
  }

  /** 只留正在播的一项；恢复 keep-open=yes。 */
  private fun clearQueuedNext() {
    if (queuedNext == null && pendingSeamlessId == null) return
    queuedNext = null
    pendingSeamlessId = null
    if (created.get()) {
      try {
        MPVLib.command(arrayOf("playlist-clear"))
      } catch (_: Throwable) {
      }
    }
    applyKeepOpenForQueue(hasQueued = false)
  }

  /**
   * 手动下一集 / keep-open 未切到 no 时的兜底：playlist-next + unpause。
   * 有排队且 keep-open=no 时主路径是 mpv 自动前进 → playlist-pos 观察进 [enterQueuedNext]。
   */
  private fun skipToQueued(next: KotvQueuedNext): Boolean {
    if (!created.get() || queuedNext !== next) return false
    return try {
      pendingSeamlessId = next.id
      MPVLib.command(arrayOf("playlist-next"))
      unpauseWithAudioFocus()
      eof = false
      true
    } catch (t: Throwable) {
      pendingSeamlessId = null
      Log.w(TAG, "skip to queued failed", t)
      false
    }
  }

  /** 已播到排好的下一集：它成为当前集，通知 Dart 换集；恢复 keep-open=yes。 */
  private fun enterQueuedNext(next: KotvQueuedNext) {
    queuedNext = null
    pendingSeamlessId = null
    applyKeepOpenForQueue(hasQueued = false)
    loadGen.incrementAndGet()
    loadedUrl = next.url
    loadedHeaders = next.headers
    currentMime = next.mime
    retriedHlsMime = false
    retriedDecodeFallback = false
    upgradedLiveFromMedia = false
    engineLive = false
    eof = false
    durationSec = 0.0
    durationFullSec = 0.0
    maxPlayedSec = 0.0
    loadWallMs = SystemClock.elapsedRealtime()
    width = 0
    height = 0
    applyQueuedSubs(next.subs)
    emit(mapOf("event" to "transition", "id" to next.id))
  }

  /** 无缝切入后挂外挂字幕（与 Dart queueNext 的 subs 一致）。 */
  private fun applyQueuedSubs(subs: List<Map<String, Any?>>) {
    if (!created.get() || subs.isEmpty()) return
    for (m in subs) {
      val path = m["path"]?.toString()?.trim().orEmpty()
      if (path.isEmpty()) continue
      val title = m["title"]?.toString()?.trim().orEmpty()
      val select = when (val raw = m["select"]) {
        is Boolean -> raw
        else -> true
      }
      val flags = if (select) "select" else "auto"
      try {
        if (title.isNotEmpty()) {
          MPVLib.command(arrayOf("sub-add", path, flags, title))
        } else {
          MPVLib.command(arrayOf("sub-add", path, flags))
        }
      } catch (t: Throwable) {
        Log.w(TAG, "queue sub-add failed", t)
      }
    }
  }

  /** User-Agent、Referer 单独成项，其余头合成一条列表。没有的项不写。 */
  private fun appendHeaderOptions(headers: Map<String, String>, opts: MutableList<String>) {
    var ua = ""
    var referer = ""
    val fields = ArrayList<String>()
    for ((rawKey, rawValue) in headers) {
      val key = rawKey.trim()
      val value = rawValue.trim()
      if (key.isEmpty() || value.isEmpty()) continue
      when {
        key.equals("User-Agent", ignoreCase = true) || key.equals("ua", ignoreCase = true) ->
          ua = value
        key.equals("Referer", ignoreCase = true) || key.equals("Referrer", ignoreCase = true) ->
          referer = value
        else -> fields.add("${escapeListValue(key)}: ${escapeListValue(value)}")
      }
    }
    if (ua.isNotEmpty()) opts.add("user-agent=$ua")
    if (referer.isNotEmpty()) opts.add("referrer=$referer")
    if (fields.isNotEmpty()) opts.add("http-header-fields=${fields.joinToString(",")}")
  }

  /** loadfile 选项按字节长度写，值里的等号和逗号不再被拆开。 */
  private fun encodeLoadfileOptions(options: List<String>): String {
    return options.joinToString(",") { option ->
      val eq = option.indexOf('=')
      val key = option.substring(0, eq)
      val value = option.substring(eq + 1)
      "${encodeLoadfilePart(key)}=${encodeLoadfilePart(value)}"
    }
  }

  private fun encodeLoadfilePart(value: String): String {
    val n = value.toByteArray(Charsets.UTF_8).size
    return "%$n%$value"
  }

  private fun escapeListValue(value: String): String =
    value.replace("\\", "\\\\").replace(",", "\\,")

  private fun setSurfaceLayerEnabled(enabled: Boolean) {
    if (surfaceLayerEnabled == enabled) {
      if (enabled) {
        tryAttachSurface()
        maybeLoadPending()
      }
      return
    }
    surfaceLayerEnabled = enabled
    val host = surfaceHost
    if (!enabled) {
      parkSurfaceTransient()
      host?.clearVideoLayer()
      surfaceReady = false
      return
    }
    if (host == null) return
    host.setRender(renderTexture)
    if (host.currentSurface() != null) {
      surfaceReady = true
      tryAttachSurface()
      maybeLoadPending()
    }
  }

  private fun destroyPlayer() {
    main.removeCallbacks(tick)
    pendingUrl = null
    loadGen.incrementAndGet()
    createdAsLive = null
    createdTlsVerify = null
    createdDiskCache = null
    createdBufferBytes = null
    createdDirect = null
    directActive = false
    videoAspect = 0.0
    appliedSpdif = null
    audioFocus.abandon()
    audioFocusVolumeMul = 1f
    if (!created.getAndSet(false)) return
    try {
      MPVLib.removeObserver(this)
    } catch (_: Throwable) {
    }
    parkSurfaceTerminal()
    try {
      MPVLib.destroyCreatedContext()
    } catch (_: Throwable) {
    }
    playing = false
    buffering = false
  }

  private fun applyVolumeProperty() {
    if (!created.get()) return
    try {
      MPVLib.setPropertyDouble("volume", volume * audioFocusVolumeMul.toDouble())
    } catch (t: Throwable) {
      Log.w(TAG, "apply volume", t)
    }
  }

  /** 开播/切集前申请焦点；失败则保持 pause。 */
  private fun unpauseWithAudioFocus() {
    if (!audioFocus.requestForPlayback()) {
      paused = true
      playing = false
      try {
        MPVLib.setPropertyBoolean("pause", true)
      } catch (_: Throwable) {
      }
      return
    }
    MPVLib.setPropertyBoolean("pause", false)
    paused = false
    playing = true
  }

  private fun emitLoadFailure(e: Throwable) {
    val msg = e.message ?: "MPV load failed"
    Log.e(TAG, msg, e)
    emit(mapOf("event" to "error", "message" to msg))
  }

  private fun emit(payload: Map<String, Any?>) {
    emitOnMain(main, eventSink, payload)
  }

  override fun eventProperty(property: String) {}

  override fun eventProperty(property: String, value: Long) {
    when (property) {
      // 排好的下一集追加在第 2 项（下标 1）。
      "playlist-pos" -> {
        val next = queuedNext
        if (next != null && value == 1L) main.post { if (queuedNext === next) enterQueuedNext(next) }
      }
      "width", "video-params/w" -> {
        width = value.toInt()
        emitSize()
      }
      "height", "video-params/h" -> {
        height = value.toInt()
        emitSize()
      }
    }
  }

  override fun eventProperty(property: String, value: Boolean) {
    when (property) {
      "pause" -> {
        paused = value
        playing = !value
      }
      "eof-reached" -> {
        if (value) {
          val gen = activeLoadGen
          main.post {
            if (loadGen.get() != gen) return@post
            markEnded()
          }
        } else {
          eof = false
        }
      }
      "paused-for-cache", "seeking" -> buffering = value
      "media-live" -> if (value) {
        val gen = activeLoadGen
        main.post {
          if (loadGen.get() != gen) return@post
          maybeUpgradeLiveFromMedia()
        }
      }
    }
  }

  override fun eventProperty(property: String, value: String) {
    when (property) {
      "current-vo" -> {
        val nextDirect = value == "mediacodec_embed"
        val changed = nextDirect != directActive
        directActive = nextDirect
        main.post {
          applyVideoFrame()
          if (changed) applyEqualizer()
        }
      }
    }
  }

  override fun eventProperty(property: String, value: Double) {
    when (property) {
      "time-pos", "playback-time" -> positionSec = value
      "duration" -> durationSec = value
      "duration/full" -> if (value > 0.0) durationFullSec = value
      "video-params/aspect" -> {
        videoAspect = value
        main.post { applyVideoFrame() }
      }
    }
  }

  /**
   * 引擎报告 media-live：升直播缓冲（关磁盘缓存 / cache-pause），保留进度再开。
   * 不改 [livePlayback]（开播标定），避免点播无缝 queueNext 被拒。
   * 只信引擎信号，不用 duration==0 启发式。
   */
  private fun maybeUpgradeLiveFromMedia() {
    if (engineLive || upgradedLiveFromMedia) return
    if (!created.get() || loadedUrl.isBlank()) return
    upgradedLiveFromMedia = true
    engineLive = true
    emit(mapOf("event" to "live", "live" to true, "engineOnly" to true))
    Log.i(TAG, "upgrade live buffer from media-live url=$loadedUrl")
    retrySeekSec = positionSec.coerceAtLeast(0.0)
    // startLoad 会清 queuedNext；升缓冲后按保留项再 append，避免无缝排队被拆掉。
    val keepQueued = queuedNext
    try {
      ensurePlayerAndReload()
      if (keepQueued != null && !livePlayback) {
        queueNext(keepQueued)
      }
    } catch (t: Throwable) {
      Log.w(TAG, "live upgrade reload failed", t)
      emitLoadFailure(t)
    }
  }

  override fun event(eventId: Int) {
    when (eventId) {
      MPVLib.MpvEvent.MPV_EVENT_START_FILE -> {
        activeLoadGen = loadGen.get()
      }
      MPVLib.MpvEvent.MPV_EVENT_FILE_LOADED, MPVLib.MpvEvent.MPV_EVENT_PLAYBACK_RESTART -> {
        // 就绪事件不按 loadGen 丢弃（只挡过期 end-file）；否则 START_FILE 未对齐时会一直不 ready。
        buffering = false
        // 属性观察可能晚于 restart；主动读一次，避免 Dart 侧一直 width=0 盖黑。
        try {
          width = MPVLib.getPropertyInt("width") ?: width
          height = MPVLib.getPropertyInt("height") ?: height
          if (width <= 0) width = MPVLib.getPropertyInt("video-params/w") ?: width
          if (height <= 0) height = MPVLib.getPropertyInt("video-params/h") ?: height
        } catch (_: Throwable) {
        }
        val seekTo = retrySeekSec
        if (seekTo >= 0.5) {
          retrySeekSec = -1.0
          try {
            MPVLib.command(arrayOf("seek", seekTo.toString(), "absolute"))
          } catch (t: Throwable) {
            Log.w(TAG, "retry seek failed", t)
          }
        } else {
          retrySeekSec = -1.0
        }
        emitSize()
        emit(mapOf("event" to "ready", "width" to width, "height" to height))
      }
      MPVLib.MpvEvent.MPV_EVENT_SHUTDOWN -> {
        created.set(false)
      }
    }
  }

  /** 单集循环时 mpv 自己从头再播，不会停在片尾，也就不报 completed。 */
  private fun loopFile(): String = if (repeatOne) "inf" else "no"

  private fun applyRepeatOne() {
    if (created.get()) MPVLib.setPropertyString("loop-file", loopFile())
  }

  /**
   * 播到片尾，每次加载只报一次 completed。
   * 无排队且 keep-open=yes：eof-reached 停末帧 → 对外 completed。
   * 有排队：主路径 keep-open=no 已自然前进；此处 skipToQueued 仅作竞态兜底。
   * 仅图片轨且未出画、几乎没播过：seek 末帧的假 EOF，报 error 而不是 completed。
   */
  private fun markEnded() {
    if (eof) return
    if (isUnplayableImageEof()) {
      eof = true
      playing = false
      queuedNext = null
      pendingSeamlessId = null
      applyKeepOpenForQueue(hasQueued = false)
      Log.w(TAG, "image-only eof suppressed url=$loadedUrl played=$maxPlayedSec")
      emit(mapOf("event" to "error", "message" to "无法解码该片源画面"))
      return
    }
    val next = queuedNext
    if (next != null) {
      main.post {
        if (queuedNext !== next) return@post
        if (!skipToQueued(next)) {
          eof = true
          playing = false
          queuedNext = null
          pendingSeamlessId = null
          applyKeepOpenForQueue(hasQueued = false)
          emit(mapOf("event" to "completed"))
        }
      }
      return
    }
    if (pendingSeamlessId != null) return
    // 标定直播且无排队：时间轴抖动勿当片尾硬切。
    if (livePlayback) return
    eof = true
    playing = false
    emit(mapOf("event" to "completed"))
  }

  /**
   * keep-open 在解不出画面的 png/mjpeg「视频」上会立刻 seek 到末帧并 eof-reached。
   * 有音轨且真正播过则放行；仅图片轨、无尺寸、开播数秒内几乎未前进 → 假片尾。
   */
  private fun isUnplayableImageEof(): Boolean {
    if (width > 0 && height > 0) return false
    val elapsed = SystemClock.elapsedRealtime() - loadWallMs
    if (elapsed > 8_000L || maxPlayedSec >= 1.0) return false
    var hasAudio = false
    var hasVideo = false
    var allVideoImage = true
    val count = try {
      MPVLib.getPropertyInt("track-list/count") ?: 0
    } catch (_: Throwable) {
      0
    }
    for (i in 0 until count) {
      val type = try {
        MPVLib.getPropertyString("track-list/$i/type")
      } catch (_: Throwable) {
        null
      } ?: continue
      when (type) {
        "audio" -> hasAudio = true
        "video" -> {
          hasVideo = true
          val codec = try {
            MPVLib.getPropertyString("track-list/$i/codec")
          } catch (_: Throwable) {
            null
          }
          val image = try {
            MPVLib.getPropertyBoolean("track-list/$i/image") ?: false
          } catch (_: Throwable) {
            false
          }
          val albumart = try {
            MPVLib.getPropertyBoolean("track-list/$i/albumart") ?: false
          } catch (_: Throwable) {
            false
          }
          if (!image && !albumart && !KotvAndroidPlayback.isImageMediaCodec(codec)) {
            allVideoImage = false
          }
        }
      }
    }
    if (hasAudio) return false
    return hasVideo && allVideoImage
  }

  override fun endFile(reason: Int, error: Int, errorText: String?) {
    val gen = activeLoadGen
    when (reason) {
      // 有排队或正在无缝切入：不算播完（keep-open=no 自然前进 / skipToQueued 兜底；旧文件 end-file 晚到也忽略）。
      MPVLib.MpvEndFileReason.MPV_END_FILE_REASON_EOF -> {
        main.post {
          if (loadGen.get() != gen) return@post
          if (queuedNext != null || pendingSeamlessId != null) return@post
          markEnded()
        }
      }
      MPVLib.MpvEndFileReason.MPV_END_FILE_REASON_ERROR -> {
        val msg = errorText?.takeIf { it.isNotBlank() } ?: "MPV error $error"
        main.post {
          if (loadGen.get() != gen) return@post
          handleLoadError(msg)
        }
      }
      else -> {}
    }
  }

  private fun emitSize() {
    if (width > 0 && height > 0) {
      emit(mapOf("event" to "size", "width" to width, "height" to height))
    }
  }

  /** IO/HLS 与解码失败各重试一次（文案判定见 [KotvAndroidPlayback]）。 */
  private fun handleLoadError(msg: String) {
    if (loadedUrl.isBlank() && pendingUrl.isNullOrBlank()) {
      emit(mapOf("event" to "error", "message" to msg))
      return
    }
    val url = loadedUrl.ifBlank { pendingUrl.orEmpty() }
    if (KotvAndroidPlayback.shouldRetryMpvHlsAfterError(msg, url, currentMime, retriedHlsMime)) {
      Log.i(TAG, "retry load with HLS demuxer after: $msg")
      retriedHlsMime = true
      currentMime = "application/x-mpegURL"
      val headers = if (loadedHeaders.isNotEmpty()) loadedHeaders else pendingHeaders
      if (url.isBlank()) {
        emit(mapOf("event" to "error", "message" to msg))
        return
      }
      retrySeekSec = positionSec.coerceAtLeast(0.0)
      eof = false
      loadGen.incrementAndGet()
      tryAttachSurface()
      if (surfaceLayerEnabled && !surfaceAttached) {
        pendingUrl = url
        pendingHeaders = LinkedHashMap(headers)
        maybeLoadPending()
      } else {
        startLoad(url, headers)
      }
      return
    }
    if (!retriedDecodeFallback && KotvAndroidPlayback.isDecodeErrorText(msg)) {
      val next = KotvAndroidPlayback.nextDecodeMode(decodeMode)
      if (next != null) {
        Log.i(TAG, "retry load with decode fallback after: $msg")
        retriedDecodeFallback = true
        decodeMode = next
        retrySeekSec = positionSec.coerceAtLeast(0.0)
        try {
          ensurePlayerAndReload()
        } catch (t: Throwable) {
          emitLoadFailure(t)
        }
        return
      }
    }
    emit(mapOf("event" to "error", "message" to msg))
  }

  private fun withOpacity(raw: String, opacityPct: Double?): String {
    if (opacityPct == null) return raw
    return applySubtitleOpacity(raw, opacityPct)
  }

  companion object {
    /** UI/引擎托管：mpv.conf 写入这些键会被跳过。 */
    private val MANAGED_CONF_OPTIONS = setOf(
      "vo", "wid", "android-surface-size", "gpu-api", "gpu-context", "hwdec",
      "audio-spdif", "android-dolby-vision-output", "demuxer-dovi-profile7",
      "cache", "cache-on-disk", "demuxer-cache-dir", "cache-secs",
      "demuxer-max-bytes", "demuxer-max-back-bytes", "cache-pause", "cache-pause-initial",
      "tls-verify", "tls-ca-file", "slang",
      "brightness", "contrast", "saturation", "gamma", "hue",
    )
    private const val TAG = "KotvMpv"
    const val VIEW_TYPE = "kotv_mpv/surface"
  }
}

internal class KotvMpvSurfaceFactory(
  private val plugin: KotvMpvPlugin,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
  override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
    val host = KotvMpvSurfaceHost(context)
    plugin.attachSurfaceHost(host)
    return object : PlatformView {
      override fun getView(): View = host
      override fun dispose() {
        Handler(Looper.getMainLooper()).post {
          plugin.detachSurfaceHost(host)
          host.release()
        }
      }
    }
  }
}

/** SurfaceView / TextureView 宿主（PlayerView.setRender）。 */
internal class KotvMpvSurfaceHost(context: Context) :
  FrameLayout(context),
  SurfaceHolder.Callback,
  TextureView.SurfaceTextureListener {

  var surfaceView: SurfaceView? = null
    private set
  var textureView: TextureView? = null
    private set
  private var textureSurface: Surface? = null
  private var useTexture = false
  var onSurface: ((Boolean) -> Unit)? = null
  /** 缓冲区宽高变化；android-surface-size 由插件统一写。 */
  var onSurfaceSize: ((Int, Int) -> Unit)? = null
  /** 最近一次回调的缓冲区宽高（"WxH"）；未知时为 null。 */
  var bufferSize: String? = null
    private set
  /** OSD Surface 可用、失效或尺寸变化时回调；插件据此挂/卸 android-osd-wid 并更新尺寸。 */
  var onOsdSurface: (() -> Unit)? = null
  /** OSD 缓冲区宽高（"WxH"）；未知时为 null。 */
  var osdSize: String? = null
    private set
  private var osdWanted = false
  private var osdView: SurfaceView? = null
  private var osdReady = false
  private val osdCallback = object : SurfaceHolder.Callback {
    override fun surfaceCreated(holder: SurfaceHolder) {
      osdReady = true
      onOsdSurface?.invoke()
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
      if (width <= 0 || height <= 0) return
      osdSize = "${width}x$height"
      onOsdSurface?.invoke()
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
      osdReady = false
      osdSize = null
      onOsdSurface?.invoke()
    }
  }

  init {
    setBackgroundColor(Color.BLACK)
    isFocusable = false
    isFocusableInTouchMode = false
    descendantFocusability = ViewGroup.FOCUS_BLOCK_DESCENDANTS
    importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
    stripPlatformViewFocus()
  }

  override fun onAttachedToWindow() {
    super.onAttachedToWindow()
    stripPlatformViewFocus()
    // OEM 可能稍后把 wrapper 设回 focusable，layout 后再剥一次。
    post { stripPlatformViewFocus() }
  }

  fun currentSurface(): Surface? {
    if (useTexture) {
      val s = textureSurface
      return if (s != null && s.isValid) s else null
    }
    val s = surfaceView?.holder?.surface
    return if (s != null && s.isValid) s else null
  }

  private var frameAspect = 0.0
  private var frameMode = "default"

  /**
   * 直出时按画面比例摆放视频 SurfaceView（aspect ≤ 0 铺满）。
   * fill 拉满；zoom 等比放大到铺满（超出部分在宿主外）；其余等比完整显示。
   */
  fun setVideoFrame(aspect: Double, mode: String) {
    if (aspect == frameAspect && mode == frameMode) return
    frameAspect = aspect
    frameMode = mode
    layoutVideoFrame()
  }

  /**
   * OSD 层与视频层同框：SurfaceView 会把整块区域从窗口挖空，
   * OSD 若比视频大，黑边处就透出窗口下层的旧画面。
   */
  private fun layoutVideoFrame() {
    if (surfaceView == null) return
    val w = width
    val h = height
    val (fw, fh) = if (frameAspect <= 0.0 || frameMode == "fill" || w <= 0 || h <= 0) {
      LayoutParams.MATCH_PARENT to LayoutParams.MATCH_PARENT
    } else {
      val cover = frameMode == "zoom"
      val byWidth = (frameAspect >= w.toDouble() / h) != cover
      if (byWidth) w to (w / frameAspect).roundToInt() else (h * frameAspect).roundToInt() to h
    }
    for (v in listOfNotNull(surfaceView, osdView)) {
      val cur = v.layoutParams
      if (cur != null && cur.width == fw && cur.height == fh) continue
      v.layoutParams = LayoutParams(fw, fh, Gravity.CENTER)
    }
  }

  override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
    super.onSizeChanged(w, h, oldw, oldh)
    post {
      layoutVideoFrame()
      stripPlatformViewFocus()
    }
  }

  fun currentOsdSurface(): Surface? {
    if (!osdReady) return null
    val s = osdView?.holder?.surface
    return if (s != null && s.isValid) s else null
  }

  /** 直出时在视频上方叠一层透明 SurfaceView 画字幕；Texture 方式不直出，不建。 */
  fun setOsdLayer(enabled: Boolean) {
    osdWanted = enabled
    syncOsdView()
  }

  private fun syncOsdView() {
    val want = osdWanted && surfaceView != null
    if (want == (osdView != null)) return
    if (!want) {
      // 先让插件卸掉 android-osd-wid，再拆 View，mpv 不会拿着已销毁的 Surface。
      osdReady = false
      onOsdSurface?.invoke()
      removeOsdView()
      return
    }
    val v = SurfaceView(context).apply {
      layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
      isFocusable = false
      isFocusableInTouchMode = false
      setZOrderMediaOverlay(true)
      holder.setFormat(PixelFormat.TRANSLUCENT)
      holder.addCallback(osdCallback)
    }
    osdView = v
    addView(v)
    layoutVideoFrame()
    stripPlatformViewFocus()
  }

  private fun removeOsdView() {
    val v = osdView ?: return
    try {
      v.holder.removeCallback(osdCallback)
    } catch (_: Throwable) {
    }
    removeView(v)
    osdView = null
    osdReady = false
    osdSize = null
  }

  fun setRender(texture: Boolean) {
    if (useTexture == texture && (surfaceView != null || textureView != null)) {
      if (currentSurface() != null) onSurface?.invoke(true)
      return
    }
    if (surfaceView != null || textureView != null) {
      onSurface?.invoke(false)
    }
    unbindViews()
    removeOsdView()
    listOfNotNull(surfaceView, textureView).forEach { removeView(it) }
    surfaceView = null
    textureView = null
    releaseTextureSurface()
    useTexture = texture
    val lp = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
    if (texture) {
      val tv = TextureView(context).apply {
        layoutParams = lp
        isFocusable = false
        isFocusableInTouchMode = false
      }
      textureView = tv
      tv.surfaceTextureListener = this
      addView(tv)
      if (tv.isAvailable) {
        bindTextureSurface(tv.surfaceTexture, tv.width, tv.height)
      }
    } else {
      val sv = SurfaceView(context).apply {
        layoutParams = lp
        isFocusable = false
        isFocusableInTouchMode = false
        // 与 Exo 一致：MediaOverlay 才能压过 Flutter 叠层，否则 Hybrid 下常见有声黑屏。
        // 滚动重影靠详情 Positioned 跟槽；勿再靠关 overlay「藏」画面。
        setZOrderMediaOverlay(true)
        holder.addCallback(this@KotvMpvSurfaceHost)
      }
      surfaceView = sv
      addView(sv)
      layoutVideoFrame()
      syncOsdView()
    }
    stripPlatformViewFocus()
  }

  /** 出画前去掉 Surface，只留黑底宿主。 */
  fun clearVideoLayer() {
    if (surfaceView == null && textureView == null) return
    onSurface?.invoke(false)
    unbindViews()
    removeOsdView()
    listOfNotNull(surfaceView, textureView).forEach { removeView(it) }
    surfaceView = null
    textureView = null
    releaseTextureSurface()
  }

  fun release() {
    unbindViews()
    removeOsdView()
    releaseTextureSurface()
    onSurface = null
    onSurfaceSize = null
    onOsdSurface = null
    removeAllViews()
  }

  private fun unbindViews() {
    try {
      surfaceView?.holder?.removeCallback(this)
    } catch (_: Throwable) {
    }
    textureView?.surfaceTextureListener = null
  }

  private fun releaseTextureSurface() {
    try {
      textureSurface?.release()
    } catch (_: Throwable) {
    }
    textureSurface = null
    bufferSize = null
  }

  private fun bindTextureSurface(st: SurfaceTexture?, width: Int, height: Int) {
    if (st == null) return
    releaseTextureSurface()
    textureSurface = Surface(st)
    applySurfaceSize(width, height)
    onSurface?.invoke(true)
  }

  private fun applySurfaceSize(width: Int, height: Int) {
    if (width <= 0 || height <= 0) return
    bufferSize = "${width}x$height"
    onSurfaceSize?.invoke(width, height)
  }

  override fun surfaceCreated(holder: SurfaceHolder) {
    onSurface?.invoke(true)
  }

  override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
    // 只更新尺寸；勿再 onSurface(true)：全屏缩放会反复触发，每次都会重播。
    applySurfaceSize(width, height)
  }

  override fun surfaceDestroyed(holder: SurfaceHolder) {
    bufferSize = null
    onSurface?.invoke(false)
  }

  override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
    bindTextureSurface(surface, width, height)
  }

  override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) {
    applySurfaceSize(width, height)
  }

  override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
    onSurface?.invoke(false)
    releaseTextureSurface()
    return true
  }

  override fun onSurfaceTextureUpdated(surface: SurfaceTexture) {}
}
