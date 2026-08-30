package com.bobo.kotv

import android.content.Context
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.SurfaceHolder
import android.view.SurfaceView
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
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONArray
import org.json.JSONObject

/**
 * 原生 MPV（对齐 TV）：[MPVLib] + SurfaceView，直出硬解。
 *
 * native 库从 assets/mpv-libs/{abi}/ 解压加载（与 TV/webhtv 同路径约定）。
 */
class KotvMpvPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler,
  MPVLib.EventObserver {

  private var channel: MethodChannel? = null
  private var events: EventChannel? = null
  private var eventSink: EventChannel.EventSink? = null
  private var appContext: Context? = null
  private var surfaceHost: KotvMpvSurfaceHost? = null

  private val main = Handler(Looper.getMainLooper())
  private val created = AtomicBoolean(false)
  private var playing = false
  private var buffering = false
  private var paused = false
  private var durationSec = 0.0
  private var positionSec = 0.0
  private var width = 0
  private var height = 0
  private var eof = false
  private var pendingUrl: String? = null
  private var pendingHeaders: Map<String, String> = emptyMap()
  private var surfaceReady = false
  private var decodeMode = "auto"
  private var gpuNext = false
  private var vulkanEnabled = false
  private var conf = ""
  private var livePlayback = false
  private var volume = 80.0
  private var rate = 1.0

  private val tick = object : Runnable {
    override fun run() {
      if (!created.get()) return
      try {
        val pos = MPVLib.getPropertyDouble("time-pos") ?: positionSec
        val dur = MPVLib.getPropertyDouble("duration") ?: durationSec
        val pause = MPVLib.getPropertyBoolean("pause") ?: paused
        val idle = MPVLib.getPropertyBoolean("idle-active") ?: false
        val coreIdle = MPVLib.getPropertyBoolean("core-idle") ?: false
        val seeking = MPVLib.getPropertyBoolean("seeking") ?: false
        val pausedForCache = MPVLib.getPropertyBoolean("paused-for-cache") ?: false
        positionSec = pos
        durationSec = dur
        paused = pause
        playing = !pause && !idle && !coreIdle
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
        // Temporary surface loss: only park VO — do not destroy MPV context.
        try {
          MPVLib.setPropertyString("vo", "null")
          MPVLib.setPropertyString("force-window", "no")
          MPVLib.detachSurface()
        } catch (_: Throwable) {
        }
      }
    }
    // Surface 可能早于 callback 就绪（详情↔全屏挪 PlatformView）。
    val holder = host.surfaceView.holder
    if (holder.surface?.isValid == true) {
      surfaceReady = true
      tryAttachSurface()
      maybeLoadPending()
    }
  }

  internal fun detachSurfaceHost(host: KotvMpvSurfaceHost) {
    if (surfaceHost === host) {
      surfaceHost = null
      surfaceReady = false
      // PlatformView dispose: detach surface only; Dart dispose() destroys player.
      try {
        if (created.get()) {
          MPVLib.setPropertyString("vo", "null")
          MPVLib.setPropertyString("force-window", "no")
          MPVLib.detachSurface()
        }
      } catch (_: Throwable) {
      }
    }
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "isVulkanAvailable" -> {
        val ctx = appContext
        result.success(ctx != null && MPVLib.isVulkanRendererAvailable(ctx))
      }
      "create" -> {
        decodeMode = call.argument<String>("decode") ?: decodeMode
        gpuNext = call.argument<Boolean>("gpuNext") == true
        vulkanEnabled = call.argument<Boolean>("vulkan") == true
        conf = call.argument<String>("conf") ?: conf
        main.post {
          try {
            ensurePlayer()
            result.success(mapOf("ok" to true, "ready" to created.get()))
          } catch (e: Throwable) {
            emitLoadFailure(e)
            result.error("CREATE_FAILED", e.message, null)
          }
        }
      }
      "open" -> {
        val url = call.argument<String>("url") ?: ""
        @Suppress("UNCHECKED_CAST")
        val headers = (call.argument<Map<*, *>>("headers") ?: emptyMap<Any, Any>())
          .entries
          .associate { "${it.key}" to "${it.value}" }
        livePlayback = call.argument<Boolean>("live") == true
        decodeMode = call.argument<String>("decode") ?: decodeMode
        gpuNext = call.argument<Boolean>("gpuNext") == true
        vulkanEnabled = call.argument<Boolean>("vulkan") == true
        conf = call.argument<String>("conf") ?: conf
        @Suppress("UNCHECKED_CAST")
        val props = (call.argument<Map<*, *>>("props") ?: emptyMap<Any, Any>())
          .entries
          .associate { "${it.key}" to "${it.value}" }
        main.post {
          try {
            ensurePlayer()
            applyRuntimeOpts(props)
            applyGpuApiIfNeeded()
            eof = false
            buffering = true
            playing = false
            positionSec = 0.0
            durationSec = 0.0
            width = 0
            height = 0
            pendingUrl = url
            pendingHeaders = headers
            if (surfaceReady) {
              maybeLoadPending()
            }
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
            MPVLib.setPropertyBoolean("pause", false)
            paused = false
            playing = true
            result.success(null)
          } catch (e: Throwable) {
            result.error("PLAY_FAILED", e.message, null)
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
            result.success(null)
          } catch (e: Throwable) {
            result.error("PAUSE_FAILED", e.message, null)
          }
        }
      }
      "stop" -> {
        main.post {
          try {
            pendingUrl = null
            if (created.get()) {
              // 对齐 TV Source.stop：先静音再 stop，避免详情 pop 后 AO 残留。
              try {
                MPVLib.setPropertyDouble("volume", 0.0)
                MPVLib.setPropertyBoolean("pause", true)
              } catch (_: Throwable) {
              }
              MPVLib.command(arrayOf("stop"))
            }
            playing = false
            buffering = false
            paused = true
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
            if (created.get()) {
              MPVLib.setPropertyDouble("volume", volume)
            }
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
        val on = call.argument<Boolean>("on") == true
        main.post {
          try {
            if (created.get()) {
              MPVLib.setPropertyString("loop-file", if (on) "inf" else "no")
            }
            result.success(null)
          } catch (e: Throwable) {
            result.error("REPEAT_FAILED", e.message, null)
          }
        }
      }
      "setDecode" -> {
        decodeMode = call.argument<String>("decode") ?: decodeMode
        main.post {
          try {
            if (created.get()) {
              MPVLib.setPropertyString("hwdec", resolveHwdec(decodeMode))
            }
            result.success(null)
          } catch (e: Throwable) {
            result.error("DECODE_FAILED", e.message, null)
          }
        }
      }
      "setOpts" -> {
        gpuNext = call.argument<Boolean>("gpuNext") == true
        vulkanEnabled = call.argument<Boolean>("vulkan") == true
        conf = call.argument<String>("conf") ?: conf
        decodeMode = call.argument<String>("decode") ?: decodeMode
        @Suppress("UNCHECKED_CAST")
        val props = (call.argument<Map<*, *>>("props") ?: emptyMap<Any, Any>())
          .entries
          .associate { "${it.key}" to "${it.value}" }
        main.post {
          try {
            applyRuntimeOpts(props)
            applyGpuApiIfNeeded()
            result.success(null)
          } catch (e: Throwable) {
            result.error("OPTS_FAILED", e.message, null)
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
      "retryVideo" -> {
        main.post {
          try {
            if (created.get()) {
              MPVLib.command(arrayOf("playlist-play-index", "current"))
              MPVLib.setPropertyBoolean("pause", false)
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

  private fun ensurePlayer() {
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
    if (created.get()) return
    synchronized(this) {
      if (created.get()) return
      val configDir = File(ctx.filesDir, "mpv").apply { mkdirs() }
      val cacheDir = File(ctx.cacheDir, "mpv").apply { mkdirs() }
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
      MPVLib.setOptionString("hwdec", resolveHwdec(decodeMode))
      if (isRockchipMpp()) {
        // RK3399/RK3588：auto-safe 会走 mediacodec-copy，Surface 未绑时必黑屏；直出 mediacodec + OMX 优化
        val board = (Build.BOARD ?: "").lowercase()
        val model = (Build.MODEL ?: "").lowercase()
        val product = (Build.PRODUCT ?: "").lowercase()
        MPVLib.setOptionString("hwdec-codecs", "all")
        val rk3399 = board.contains("rk3399") ||
            model.contains("rk3399") ||
            model.contains("cr19") ||
            product.contains("rk3399") ||
            product.contains("rk3399_box")
        if (rk3399) {
          MPVLib.setOptionString("hwdec-extraframes", "8")
          MPVLib.setOptionString("mediacodec-hevc", "yes")
          MPVLib.setOptionString("vd-lavc-dr", "no")
        }
      }
      MPVLib.setOptionString("vo", if (gpuNext) "gpu-next" else "gpu")
      MPVLib.setOptionString("gpu-context", "android")
      applyGpuApiOptions()
      // TV boxes often fail scraped HTTPS CA checks; disable verify for now.
      MPVLib.setOptionString("tls-verify", "no")
      // ytdl_hook aborts load on devices without youtube-dl; disable.
      MPVLib.setOptionString("ytdl", "no")
      // Do not force gpu-api=vulkan on API 25: GLES path for picture;
      // libvulkan.so is only to satisfy libmpv DT_NEEDED.
      MPVLib.setOptionString("force-window", "no")
      MPVLib.setOptionString("idle", "yes")
      MPVLib.setOptionString("keep-open", "yes")
      if (!livePlayback) {
        MPVLib.setOptionString("cache", "yes")
        MPVLib.setOptionString("demuxer-max-bytes", "48MiB")
      }
      applyConfOptions(conf)
      MPVLib.init()
      MPVLib.setOptionString("force-window", "no")
      MPVLib.addObserver(this)
      observeProps()
      created.set(true)
      main.removeCallbacks(tick)
      main.post(tick)
      Log.i(TAG, "MPV context ready abi=${MPVLib.getLoadedAbi()}")
    }
  }

  /** API33+ 且 bundled/device 支持 Vulkan 时设 gpu-api=vulkan（对齐 TV mpvVulkan）。 */
  private fun applyGpuApiOptions() {
    val ctx = appContext
    if (vulkanEnabled && ctx != null && MPVLib.isVulkanRendererAvailable(ctx)) {
      MPVLib.setOptionString("gpu-api", "vulkan")
    } else {
      MPVLib.setOptionString("gpu-api", "opengl")
      MPVLib.setOptionString("opengl-es", "yes")
    }
  }

  private fun applyGpuApiIfNeeded() {
    if (!created.get()) return
    val ctx = appContext ?: return
    val useVulkan = vulkanEnabled && MPVLib.isVulkanRendererAvailable(ctx)
    try {
      MPVLib.setPropertyString("gpu-api", if (useVulkan) "vulkan" else "opengl")
      if (!useVulkan) {
        MPVLib.setPropertyString("opengl-es", "yes")
      }
    } catch (_: Throwable) {
    }
  }

  /** 音轨列表（含 AV3A 等 FFmpeg/libarcdav3a 解码轨），对齐 TV mpvplayer。 */
  private fun buildAudioTracksJson(): String {
    if (!created.get()) return "[]"
    val count = MPVLib.getPropertyInt("track-list/count") ?: 0
    val arr = JSONArray()
    for (i in 0 until count) {
      val type = MPVLib.getPropertyString("track-list/$i/type") ?: continue
      if (type != "audio") continue
      val obj = JSONObject()
      obj.put("id", MPVLib.getPropertyString("track-list/$i/id") ?: "auto")
      obj.put("title", MPVLib.getPropertyString("track-list/$i/title") ?: "")
      obj.put("lang", MPVLib.getPropertyString("track-list/$i/lang") ?: "")
      obj.put("codec", MPVLib.getPropertyString("track-list/$i/codec") ?: "")
      arr.put(obj)
    }
    return arr.toString()
  }

  /** RK3399 等 Rockchip 盒：auto → mediacodec（直出 Surface；Dart auto-safe 由原生覆盖）。 */
  private fun isRockchipMpp(): Boolean {
    val hw = (Build.HARDWARE ?: "").lowercase()
    val board = (Build.BOARD ?: "").lowercase()
    val model = (Build.MODEL ?: "").lowercase()
    val product = (Build.PRODUCT ?: "").lowercase()
    return hw.contains("rk") ||
        board.contains("rk3399") ||
        board.contains("rk3588") ||
        model.contains("rk3399") ||
        model.contains("cr19") ||
        product.contains("rk3399") ||
        product.contains("rk3399_box")
  }

  /** 映射 Dart decode 字符串；RK 盒 auto → mediacodec（直出 Surface，勿 copy）。 */
  private fun resolveHwdec(raw: String?): String {
    val mode = raw?.trim().orEmpty()
    if (mode == "no" || mode == "soft" || mode == "software" || mode == "sw") return "no"
    if (mode == "mediacodec" || mode == "hard" || mode == "hardware" || mode == "hw") {
      return "mediacodec"
    }
    if ((mode.isBlank() || mode == "auto") && isRockchipMpp()) {
      return "mediacodec"
    }
    return mode.ifBlank { "auto-safe" }
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
      if (key.isEmpty() || key == "vo" || key == "wid" || key == "android-surface-size") continue
      try {
        MPVLib.setOptionString(key, value.ifEmpty { "yes" })
      } catch (_: Throwable) {
      }
    }
  }

  private fun applyRuntimeOpts(props: Map<String, String>) {
    if (!created.get()) return
    val hw = resolveHwdec(props["hwdec"] ?: decodeMode)
    try {
      MPVLib.setPropertyString("hwdec", hw)
    } catch (_: Throwable) {
    }
    val vo = if (gpuNext || props["vo"] == "gpu-next") "gpu-next" else "gpu"
    if (surfaceReady) {
      try {
        MPVLib.setPropertyString("vo", vo)
      } catch (_: Throwable) {
      }
    }
    for ((k, v) in props) {
      if (k == "hwdec" || k == "vo" || k == "wid" || k == "android-surface-size") continue
      try {
        MPVLib.setPropertyString(k, v)
      } catch (_: Throwable) {
      }
    }
  }

  private fun observeProps() {
    MPVLib.observeProperty("time-pos", MPVLib.MpvFormat.MPV_FORMAT_DOUBLE)
    MPVLib.observeProperty("duration", MPVLib.MpvFormat.MPV_FORMAT_DOUBLE)
    MPVLib.observeProperty("pause", MPVLib.MpvFormat.MPV_FORMAT_FLAG)
    MPVLib.observeProperty("paused-for-cache", MPVLib.MpvFormat.MPV_FORMAT_FLAG)
    MPVLib.observeProperty("seeking", MPVLib.MpvFormat.MPV_FORMAT_FLAG)
    MPVLib.observeProperty("eof-reached", MPVLib.MpvFormat.MPV_FORMAT_FLAG)
    MPVLib.observeProperty("width", MPVLib.MpvFormat.MPV_FORMAT_INT64)
    MPVLib.observeProperty("height", MPVLib.MpvFormat.MPV_FORMAT_INT64)
    MPVLib.observeProperty("video-params/w", MPVLib.MpvFormat.MPV_FORMAT_INT64)
    MPVLib.observeProperty("video-params/h", MPVLib.MpvFormat.MPV_FORMAT_INT64)
  }

  private fun tryAttachSurface() {
    if (!created.get()) return
    val surface = surfaceHost?.surfaceView?.holder?.surface ?: return
    if (!surface.isValid) return
    try {
      MPVLib.attachSurface(surface)
      MPVLib.setOptionString("force-window", "yes")
      val vo = if (gpuNext) "gpu-next" else "gpu"
      MPVLib.setPropertyString("vo", vo)
      val w = surfaceHost?.width ?: 0
      val h = surfaceHost?.height ?: 0
      if (w > 0 && h > 0) {
        MPVLib.setPropertyString("android-surface-size", "${w}x${h}")
      }
      // 详情↔全屏换 Surface 后恢复输出（vo 曾被置 null）。
      if (pendingUrl == null) {
        MPVLib.setPropertyBoolean("pause", false)
        MPVLib.command(arrayOf("playlist-play-index", "current"))
      }
    } catch (e: Throwable) {
      Log.e(TAG, "attachSurface", e)
    }
  }

  private fun maybeLoadPending() {
    val url = pendingUrl ?: return
    if (!created.get() || !surfaceReady) return
    pendingUrl = null
    val headers = pendingHeaders
    try {
      tryAttachSurface()
      if (headers.isNotEmpty()) {
        val hline = headers.entries.joinToString("\r\n") { "${it.key}: ${it.value}" } + "\r\n"
        MPVLib.setOptionString("http-header-fields", hline)
      }
      MPVLib.setPropertyDouble("volume", volume)
      MPVLib.setPropertyDouble("speed", rate)
      MPVLib.command(arrayOf("loadfile", url, "replace"))
      MPVLib.setPropertyBoolean("pause", false)
      buffering = true
      eof = false
    } catch (e: Throwable) {
      emit(mapOf("event" to "error", "message" to (e.message ?: "load failed")))
    }
  }

  private fun destroyPlayer() {
    main.removeCallbacks(tick)
    pendingUrl = null
    if (!created.getAndSet(false)) return
    try {
      MPVLib.removeObserver(this)
    } catch (_: Throwable) {
    }
    try {
      MPVLib.setPropertyString("vo", "null")
      MPVLib.setPropertyString("force-window", "no")
      MPVLib.detachSurface()
    } catch (_: Throwable) {
    }
    try {
      MPVLib.destroyCreatedContext()
    } catch (_: Throwable) {
    }
    playing = false
    buffering = false
  }

  private fun emitLoadFailure(e: Throwable) {
    val msg = e.message ?: "MPV load failed"
    Log.e(TAG, msg, e)
    emit(mapOf("event" to "error", "message" to msg))
  }

  private fun emit(payload: Map<String, Any?>) {
    main.post {
      try {
        eventSink?.success(payload)
      } catch (_: Throwable) {
      }
    }
  }

  override fun eventProperty(property: String) {}

  override fun eventProperty(property: String, value: Long) {
    when (property) {
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
          eof = true
          playing = false
          emit(mapOf("event" to "completed"))
        }
      }
      "paused-for-cache", "seeking" -> buffering = value
    }
  }

  override fun eventProperty(property: String, value: String) {}

  override fun eventProperty(property: String, value: Double) {
    when (property) {
      "time-pos" -> positionSec = value
      "duration" -> durationSec = value
    }
  }

  override fun event(eventId: Int) {
    when (eventId) {
      MPVLib.MpvEvent.MPV_EVENT_FILE_LOADED, MPVLib.MpvEvent.MPV_EVENT_PLAYBACK_RESTART -> {
        buffering = false
        emitSize()
        emit(mapOf("event" to "ready", "width" to width, "height" to height))
      }
      MPVLib.MpvEvent.MPV_EVENT_END_FILE -> {
        // endFile 回调会带 reason；这里兜底
      }
      MPVLib.MpvEvent.MPV_EVENT_SHUTDOWN -> {
        created.set(false)
      }
    }
  }

  override fun endFile(reason: Int, error: Int, errorText: String?) {
    when (reason) {
      MPVLib.MpvEndFileReason.MPV_END_FILE_REASON_EOF -> {
        eof = true
        playing = false
        emit(mapOf("event" to "completed"))
      }
      MPVLib.MpvEndFileReason.MPV_END_FILE_REASON_ERROR -> {
        val msg = errorText?.takeIf { it.isNotBlank() } ?: "MPV error $error"
        emit(mapOf("event" to "error", "message" to msg))
      }
      else -> {}
    }
  }

  private fun emitSize() {
    if (width > 0 && height > 0) {
      emit(mapOf("event" to "size", "width" to width, "height" to height))
    }
  }

  companion object {
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

/** SurfaceView 宿主：对齐 TV / Exo，Hybrid Composition 直出。 */
internal class KotvMpvSurfaceHost(context: Context) : FrameLayout(context), SurfaceHolder.Callback {
  val surfaceView: SurfaceView = SurfaceView(context).apply {
    layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
    isFocusable = false
    isFocusableInTouchMode = false
    holder.addCallback(this@KotvMpvSurfaceHost)
    // Hybrid Composition：媒体层叠在 Flutter 下，避免抢遥控器焦点。
    setZOrderMediaOverlay(true)
  }
  var onSurface: ((Boolean) -> Unit)? = null

  init {
    setBackgroundColor(Color.BLACK)
    isFocusable = false
    isFocusableInTouchMode = false
    descendantFocusability = ViewGroup.FOCUS_BLOCK_DESCENDANTS
    importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
    addView(surfaceView)
    stripPlatformViewFocus()
  }

  fun release() {
    try {
      surfaceView.holder.removeCallback(this)
    } catch (_: Throwable) {
    }
    onSurface = null
    removeAllViews()
  }

  override fun surfaceCreated(holder: SurfaceHolder) {
    onSurface?.invoke(true)
  }

  override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
    try {
      // Only touch natives if libs actually loaded (avoid "No implementation found").
      if (MPVLib.getLoadedAbi() != null) {
        MPVLib.setPropertyString("android-surface-size", "${width}x$height")
      }
    } catch (_: Throwable) {
    }
    onSurface?.invoke(true)
  }

  override fun surfaceDestroyed(holder: SurfaceHolder) {
    onSurface?.invoke(false)
  }
}
