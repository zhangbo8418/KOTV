package com.bobo.kotv

import android.app.ActivityManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.LoadControl
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector
import androidx.media3.exoplayer.mediacodec.MediaCodecUtil
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.upstream.DefaultBandwidthMeter
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit
import kotlin.math.max
import kotlin.math.min

/**
 * 对齐 TV Exo：OkHttpDataSource + Media3，带 headers / mime / DRM / 软硬解。
 *
 * 软硬解用 stock Media3 的 [DefaultRenderersFactory.setExtensionRendererMode]：
 * - hard/auto：EXTENSION_RENDERER_MODE_ON（MediaCodec 优先，扩展作回退）
 * - soft：EXTENSION_RENDERER_MODE_PREFER + 优先软件 MediaCodec
 *
 * TV 私有 AAR 的 setFfmpegVideoPrefer 不可用；官方 FFmpeg 扩展主要为音频，
 * 需自行编进 APK 才会被 EXTENSION 模式拾取。Flutter 侧用 Texture 渲染。
 */
class KotvExoPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

  private var channel: MethodChannel? = null
  private var events: EventChannel? = null
  private var eventSink: EventChannel.EventSink? = null
  private var appContext: Context? = null
  private var textures: TextureRegistry? = null

  private var entry: TextureRegistry.SurfaceTextureEntry? = null
  private var surface: Surface? = null
  private var player: ExoPlayer? = null
  private var currentUrl: String = ""
  private var currentHeaders: Map<String, String> = emptyMap()
  private var currentMime: String? = null
  private var currentDrm: Map<String, Any?>? = null
  private var formatRetried = false
  /** auto | soft | hard；对齐 TV 软硬解语义（stock Media3 EXTENSION 模式）。 */
  private var decodeMode: String = "auto"
  /** auto 下硬解失败后仅软解重建一次。 */
  private var decodeFallbackTried = false
  /** 估算下载速度 bytes/s：优先用累计加载字节差分（bitrateEstimate 会长时间黏在第一帧）。 */
  @Volatile private var speedBps: Long = 0
  private var speedLastBytes: Long = -1
  private var speedLastAtMs: Long = 0

  private val main = Handler(Looper.getMainLooper())
  private val tick = object : Runnable {
    override fun run() {
      val p = player ?: return
      emit(
        mapOf(
          "event" to "position",
          "positionMs" to p.currentPosition,
          "durationMs" to p.duration.coerceAtLeast(0),
          "bufferedMs" to p.bufferedPosition,
          "playing" to p.isPlaying,
          "buffering" to (p.playbackState == Player.STATE_BUFFERING),
          "speedBps" to speedBps,
        ),
      )
      main.postDelayed(this, 400)
    }
  }

  private val httpClient: OkHttpClient by lazy {
    OkHttpClient.Builder()
      .followRedirects(true)
      .followSslRedirects(true)
      .connectTimeout(15, TimeUnit.SECONDS)
      .readTimeout(20, TimeUnit.SECONDS)
      .writeTimeout(20, TimeUnit.SECONDS)
      .build()
  }

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    appContext = binding.applicationContext
    textures = binding.textureRegistry
    channel = MethodChannel(binding.binaryMessenger, "kotv_exo").also {
      it.setMethodCallHandler(this)
    }
    events = EventChannel(binding.binaryMessenger, "kotv_exo/events").also {
      it.setStreamHandler(this)
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    releasePlayer()
    channel?.setMethodCallHandler(null)
    channel = null
    events?.setStreamHandler(null)
    events = null
    textures = null
    appContext = null
  }

  override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
    eventSink = events
  }

  override fun onCancel(arguments: Any?) {
    eventSink = null
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "create" -> {
        try {
          val id = ensureTexture()
          result.success(id)
        } catch (t: Throwable) {
          result.error("exo_create", t.message, null)
        }
      }
      "open" -> {
        val url = call.argument<String>("url")?.trim().orEmpty()
        if (url.isEmpty()) {
          result.error("exo_open", "empty url", null)
          return
        }
        @Suppress("UNCHECKED_CAST")
        val headers = (call.argument<Map<String, Any?>>("headers") ?: emptyMap())
          .mapNotNull { (k, v) ->
            val key = k.trim()
            val value = v?.toString()?.trim().orEmpty()
            if (key.isEmpty() || value.isEmpty()) null else key to value
          }
          .toMap()
        val mime = call.argument<String>("mime")?.trim()?.ifEmpty { null }
        @Suppress("UNCHECKED_CAST")
        val drm = call.argument<Map<String, Any?>>("drm")
        val mode = call.argument<String>("decodeMode")?.trim()?.lowercase().orEmpty()
        main.post {
          try {
            if (mode.isNotEmpty()) {
              decodeMode = normalizeDecodeMode(mode)
            }
            decodeFallbackTried = false
            openInternal(url, headers, mime, drm)
            result.success(true)
          } catch (t: Throwable) {
            result.error("exo_open", t.message, null)
          }
        }
      }
      "setDecodeMode" -> {
        val mode = normalizeDecodeMode(call.argument<String>("mode")?.trim().orEmpty())
        main.post {
          try {
            decodeMode = mode
            decodeFallbackTried = false
            if (currentUrl.isNotEmpty()) {
              openInternal(currentUrl, currentHeaders, currentMime, currentDrm)
            }
            result.success(true)
          } catch (t: Throwable) {
            result.error("exo_decode", t.message, null)
          }
        }
      }
      "play" -> {
        main.post { player?.play(); result.success(true) }
      }
      "pause" -> {
        main.post { player?.pause(); result.success(true) }
      }
      "stop" -> {
        main.post {
          player?.pause()
          player?.seekTo(0)
          result.success(true)
        }
      }
      "seek" -> {
        val ms = (call.argument<Number>("positionMs")?.toLong() ?: 0L).coerceAtLeast(0)
        main.post { player?.seekTo(ms); result.success(true) }
      }
      "setVolume" -> {
        val v = (call.argument<Number>("volume")?.toFloat() ?: 1f).coerceIn(0f, 1f)
        main.post { player?.volume = v; result.success(true) }
      }
      "setRate" -> {
        val r = (call.argument<Number>("rate")?.toFloat() ?: 1f).coerceIn(0.25f, 4f)
        main.post {
          player?.setPlaybackSpeed(r)
          result.success(true)
        }
      }
      "dispose" -> {
        main.post {
          releasePlayer()
          result.success(true)
        }
      }
      else -> result.notImplemented()
    }
  }

  private fun ensureTexture(): Long {
    if (entry != null) return entry!!.id()
    val reg = textures ?: error("texture registry missing")
    val e = reg.createSurfaceTexture()
    entry = e
    surface = Surface(e.surfaceTexture())
    return e.id()
  }

  private fun openInternal(
    url: String,
    headers: Map<String, String>,
    mime: String?,
    drm: Map<String, Any?>?,
  ) {
    val ctx = appContext ?: error("no context")
    ensureTexture()
    formatRetried = false
    currentUrl = url
    currentHeaders = normalizeHeaders(headers)
    currentMime = mime ?: guessMime(url)
    currentDrm = drm
    speedBps = 0
    speedLastBytes = -1
    speedLastAtMs = 0

    val old = player
    player = null
    old?.release()

    val httpFactory = OkHttpDataSource.Factory(httpClient)
      .setUserAgent(currentHeaders["User-Agent"] ?: DEFAULT_UA)
      .setDefaultRequestProperties(currentHeaders)
    val dataSourceFactory = DefaultDataSource.Factory(ctx, httpFactory)
    val mediaSourceFactory = DefaultMediaSourceFactory(ctx).setDataSourceFactory(dataSourceFactory)
    val effective = effectiveDecodeMode()
    val renderers = buildRenderersFactory(ctx, effective)
    // 按设备内存定字节上限；时间窗仅作上限兜底，不以「囤满 N 分钟」为目标。
    val budget = bufferBudgetBytes(ctx)
    val loadControl: LoadControl = DefaultLoadControl.Builder()
      .setBufferDurationsMs(
        /* minBufferMs：低于目标字节时的软偏好 */ 5_000,
        /* maxBufferMs：足够大，真正刹车靠 targetBufferBytes */ 3_600_000,
        /* bufferForPlaybackMs */ 1_200,
        /* bufferForPlaybackAfterRebufferMs */ 2_500,
      )
      .setTargetBufferBytes(budget)
      .setPrioritizeTimeOverSizeThresholds(false)
      .build()
    val bandwidthMeter = DefaultBandwidthMeter.getSingletonInstance(ctx)

    val p = ExoPlayer.Builder(ctx)
      .setMediaSourceFactory(mediaSourceFactory)
      .setRenderersFactory(renderers)
      .setLoadControl(loadControl)
      .setBandwidthMeter(bandwidthMeter)
      .build()
    player = p
    p.setVideoSurface(surface)
    p.addAnalyticsListener(
      object : AnalyticsListener {
        override fun onBandwidthEstimate(
          eventTime: AnalyticsListener.EventTime,
          totalLoadTimeMs: Int,
          totalBytesLoaded: Long,
          bitrateEstimate: Long,
        ) {
          val now = android.os.SystemClock.elapsedRealtime()
          val prevBytes = speedLastBytes
          val prevAt = speedLastAtMs
          if (prevBytes >= 0 && totalBytesLoaded >= prevBytes && now > prevAt) {
            val dt = now - prevAt
            if (dt >= 200L) {
              speedBps = ((totalBytesLoaded - prevBytes) * 1000L / dt).coerceAtLeast(0)
              speedLastBytes = totalBytesLoaded
              speedLastAtMs = now
              return
            }
          } else {
            speedLastBytes = totalBytesLoaded
            speedLastAtMs = now
          }
          // 首样本或间隔过短：退回 BandwidthMeter 瞬时估值（bits/s → bytes/s）
          if (bitrateEstimate > 0) {
            speedBps = (bitrateEstimate / 8L).coerceAtLeast(0)
          }
        }
      },
    )
    p.addListener(object : Player.Listener {
      override fun onPlaybackStateChanged(playbackState: Int) {
        if (playbackState == Player.STATE_ENDED) {
          emit(mapOf("event" to "completed"))
        }
        if (playbackState == Player.STATE_READY) {
          val f = p.videoSize
          emit(
            mapOf(
              "event" to "ready",
              "width" to f.width,
              "height" to f.height,
              "durationMs" to p.duration.coerceAtLeast(0),
              "decodeMode" to effective,
            ),
          )
        }
      }

      override fun onPlayerError(error: PlaybackException) {
        Log.e(TAG, "exo error code=${error.errorCode} mode=$effective ${error.message}", error)
        if (!formatRetried) {
          val retryMime = mimeForError(error.errorCode)
          if (retryMime != null && retryMime != currentMime) {
            formatRetried = true
            currentMime = retryMime
            try {
              p.setMediaItem(buildMediaItem(currentUrl, currentMime, currentDrm), true)
              p.prepare()
              p.play()
              return
            } catch (t: Throwable) {
              Log.e(TAG, "exo retry failed", t)
            }
          }
        }
        // 对齐 TV：硬解失败时用扩展/软解重建一次
        if (decodeMode == "auto" && !decodeFallbackTried && isDecoderError(error.errorCode)) {
          decodeFallbackTried = true
          Log.w(TAG, "exo decoder failed → soft rebuild")
          try {
            openInternal(currentUrl, currentHeaders, currentMime, currentDrm)
            return
          } catch (t: Throwable) {
            Log.e(TAG, "exo soft rebuild failed", t)
          }
        }
        emit(mapOf("event" to "error", "message" to (error.message ?: error.errorCodeName)))
      }

      override fun onVideoSizeChanged(videoSize: androidx.media3.common.VideoSize) {
        emit(mapOf("event" to "size", "width" to videoSize.width, "height" to videoSize.height))
      }
    })
    p.setMediaItem(buildMediaItem(url, currentMime, currentDrm), true)
    p.prepare()
    p.play()
    main.removeCallbacks(tick)
    main.post(tick)
  }

  private fun effectiveDecodeMode(): String {
    if (decodeMode == "auto" && decodeFallbackTried) return "soft"
    return decodeMode
  }

  private fun buildRenderersFactory(ctx: Context, mode: String): DefaultRenderersFactory {
    // soft → PREFER（扩展 FFmpeg 优先，若已编入）；hard/auto → ON（MediaCodec 优先）
    val extMode = when (mode) {
      "soft" -> DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER
      else -> DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON
    }
    val factory = DefaultRenderersFactory(ctx)
      .setExtensionRendererMode(extMode)
      .setEnableDecoderFallback(true)
    if (mode == "soft") {
      factory.setMediaCodecSelector(SOFT_PREFER_SELECTOR)
    }
    return factory
  }

  private fun buildMediaItem(url: String, mime: String?, drm: Map<String, Any?>?): MediaItem {
    val b = MediaItem.Builder().setUri(url)
    if (!mime.isNullOrBlank()) b.setMimeType(mime)
    buildDrmConfig(drm)?.let { b.setDrmConfiguration(it) }
    return b.build()
  }

  /** 对齐 TV MediaItemFactory.buildDrmConfig / bean.Drm */
  private fun buildDrmConfig(drm: Map<String, Any?>?): MediaItem.DrmConfiguration? {
    if (drm == null) return null
    val type = drm["type"]?.toString()?.trim()?.lowercase().orEmpty()
    val key = drm["key"]?.toString()?.trim().orEmpty()
    if (type.isEmpty() || key.isEmpty()) return null
    val uuid = when {
      type.contains("widevine") -> C.WIDEVINE_UUID
      type.contains("playready") -> C.PLAYREADY_UUID
      type.contains("clearkey") -> C.CLEARKEY_UUID
      else -> return null
    }
    val forceKey = drm["forceKey"] == true || drm["forceKey"] == 1
    @Suppress("UNCHECKED_CAST")
    val hdrRaw = drm["header"] as? Map<*, *>
    val licenseHeaders = linkedMapOf<String, String>()
    hdrRaw?.forEach { (k, v) ->
      val kk = k?.toString()?.trim().orEmpty()
      val vv = v?.toString()?.trim().orEmpty()
      if (kk.isNotEmpty() && vv.isNotEmpty()) licenseHeaders[kk] = vv
    }
    val builder = MediaItem.DrmConfiguration.Builder(uuid)
      .setLicenseUri(key)
      .setForceDefaultLicenseUri(forceKey)
      .setMultiSession(uuid != C.CLEARKEY_UUID)
    if (licenseHeaders.isNotEmpty()) {
      builder.setLicenseRequestHeaders(licenseHeaders)
    }
    return builder.build()
  }

  private fun releasePlayer() {
    main.removeCallbacks(tick)
    player?.release()
    player = null
    surface?.release()
    surface = null
    entry?.release()
    entry = null
    currentUrl = ""
    currentHeaders = emptyMap()
    currentMime = null
    currentDrm = null
    formatRetried = false
    decodeFallbackTried = false
  }

  private fun emit(payload: Map<String, Any?>) {
    main.post {
      try {
        eventSink?.success(payload)
      } catch (_: Throwable) {
      }
    }
  }

  /** 与 Dart [KotvBufferBudget] 对齐：约 5% 总内存，且 ≤ 可用 20%；钳到 24–128MiB。 */
  private fun bufferBudgetBytes(ctx: Context): Int {
    return try {
      val am = ctx.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
      val mi = ActivityManager.MemoryInfo()
      am.getMemoryInfo(mi)
      var budget = (mi.totalMem * 0.05).toLong()
      if (mi.availMem > 0) {
        val byAvail = (mi.availMem * 0.20).toLong()
        if (byAvail in 1 until budget) budget = byAvail
      }
      val minB = 24L * 1024 * 1024
      val maxB = 128L * 1024 * 1024
      max(minB, min(maxB, budget)).toInt()
    } catch (_: Throwable) {
      64 * 1024 * 1024
    }
  }

  companion object {
    private const val TAG = "KotvExo"
    private const val DEFAULT_UA =
      "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"

    /** 软解：优先软件 MediaCodec；无软件实现时回落原列表。 */
    private val SOFT_PREFER_SELECTOR = MediaCodecSelector { mimeType, requiresSecureDecoder, requiresTunnelingDecoder ->
      val infos = MediaCodecUtil.getDecoderInfos(mimeType, requiresSecureDecoder, requiresTunnelingDecoder)
      val soft = infos.filter { !it.hardwareAccelerated }
      if (soft.isNotEmpty()) soft else infos
    }

    fun normalizeDecodeMode(raw: String): String {
      return when (raw.lowercase()) {
        "soft", "software", "sw" -> "soft"
        "hard", "hardware", "hw" -> "hard"
        else -> "auto"
      }
    }

    fun isDecoderError(errorCode: Int): Boolean {
      return errorCode == PlaybackException.ERROR_CODE_DECODER_INIT_FAILED ||
        errorCode == PlaybackException.ERROR_CODE_DECODER_QUERY_FAILED ||
        errorCode == PlaybackException.ERROR_CODE_DECODING_FAILED ||
        errorCode == PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES ||
        errorCode == PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED
    }

    fun normalizeHeaders(raw: Map<String, String>): Map<String, String> {
      val out = linkedMapOf(
        "User-Agent" to DEFAULT_UA,
        "Accept" to "*/*",
        "Connection" to "keep-alive",
      )
      for ((k0, v0) in raw) {
        var k = k0.trim()
        var v = v0.trim()
        if (k.isEmpty() || v.isEmpty()) continue
        // CatVod 偶发把多头塞进一个 value：User-Agent$xx#Referer$yy
        if (v.contains('$') && (v.contains('#') || k.equals("header", true))) {
          parseCatvodHeaderBlob(v).forEach { (hk, hv) -> out[canonicalHeader(hk)] = hv }
          continue
        }
        k = canonicalHeader(k)
        out[k] = v
      }
      return out
    }

    private fun parseCatvodHeaderBlob(blob: String): Map<String, String> {
      val map = linkedMapOf<String, String>()
      for (part in blob.split('#')) {
        val i = part.indexOf('$')
        if (i <= 0) continue
        val k = part.substring(0, i).trim()
        val v = part.substring(i + 1).trim()
        if (k.isNotEmpty() && v.isNotEmpty()) map[k] = v
      }
      return map
    }

    private fun canonicalHeader(k: String): String {
      return when (k.lowercase()) {
        "user-agent", "ua" -> "User-Agent"
        "referer", "referrer" -> "Referer"
        "cookie" -> "Cookie"
        "origin" -> "Origin"
        "host" -> "Host"
        else -> k
      }
    }

    fun guessMime(url: String): String? {
      val u = url.lowercase()
      return when {
        u.contains(".m3u8") || u.contains("m3u8") -> MimeTypes.APPLICATION_M3U8
        u.contains(".mpd") -> MimeTypes.APPLICATION_MPD
        u.contains(".ism") || u.contains("mpd/") -> MimeTypes.APPLICATION_SS
        else -> null
      }
    }

    fun mimeForError(errorCode: Int): String? {
      return when (errorCode) {
        PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED,
        PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED,
        PlaybackException.ERROR_CODE_IO_UNSPECIFIED,
        -> MimeTypes.APPLICATION_M3U8
        PlaybackException.ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED,
        PlaybackException.ERROR_CODE_PARSING_MANIFEST_MALFORMED,
        -> "application/octet-stream" // Media3 无 APPLICATION_OCTET_STREAM 常量；清 mime 提示让其嗅探
        else -> null
      }
    }
  }
}
