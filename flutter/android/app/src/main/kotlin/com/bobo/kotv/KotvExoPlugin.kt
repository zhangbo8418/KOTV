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
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.TransferListener
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.LoadControl
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
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.max
import kotlin.math.min

/**
 * 对齐 TV Exo：OkHttpDataSource + Media3，带 headers / mime / DRM / 软硬解。
 *
 * 画面路径：MediaCodec 解到 Flutter [SurfaceTexture] 的 [Surface]（[ExoPlayer.setVideoSurface]），
 * 即硬解**直出**到 GPU Texture；不按 H.264/HEVC 做应用层白名单，交给 MediaCodec 协商。
 * （Flutter Texture 不能走 Android TV 式 tunnel；关 tunnel 不等于 copy。）
 *
 * 软硬解：
 * - hard：仅 MediaCodec，优先 hardwareAccelerated；扩展 FFmpeg 不参与视频
 * - auto：MediaCodec 硬解优先，扩展可作回退；解码失败再整实例软解重建一次
 * - soft：EXTENSION PREFER + 软件 MediaCodec 优先
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
  /** auto | soft | hard；硬/自动优先 MediaCodec 硬解直出。 */
  private var decodeMode: String = "auto"
  /** auto 下硬解失败后仅软解重建一次。 */
  private var decodeFallbackTried = false
  /** 实时下载速度：TransferListener 累计网络字节，tick 里差分；无增长则归零（避免黏第一帧）。 */
  @Volatile private var speedBps: Long = 0
  private var speedLastBytes: Long = -1
  private var speedLastAtMs: Long = 0
  private val transferredBytes = AtomicLong(0)
  private val netTransferListener =
    object : TransferListener {
      override fun onTransferInitializing(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {}

      override fun onTransferStart(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {}

      override fun onTransferEnd(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {}

      override fun onBytesTransferred(
        source: DataSource,
        dataSpec: DataSpec,
        isNetwork: Boolean,
        bytesTransferred: Int,
      ) {
        if (isNetwork && bytesTransferred > 0) {
          transferredBytes.addAndGet(bytesTransferred.toLong())
        }
      }
    }

  private val main = Handler(Looper.getMainLooper())
  private val tick = object : Runnable {
    override fun run() {
      val p = player ?: return
      refreshSpeedFromTransfers()
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
      main.postDelayed(this, 300)
    }
  }

  /** 每 tick 用累计传输字节算瞬时速率；字节不涨则速度归 0。 */
  private fun refreshSpeedFromTransfers() {
    val now = android.os.SystemClock.elapsedRealtime()
    val bytes = transferredBytes.get()
    val prev = speedLastBytes
    val prevAt = speedLastAtMs
    if (prev < 0) {
      speedLastBytes = bytes
      speedLastAtMs = now
      speedBps = 0
      return
    }
    val dt = now - prevAt
    if (dt < 200L) return
    val delta = bytes - prev
    speedBps = if (delta > 0L) (delta * 1000L / dt).coerceAtLeast(0) else 0
    speedLastBytes = bytes
    speedLastAtMs = now
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
    transferredBytes.set(0)

    val old = player
    player = null
    old?.release()

    val httpFactory = OkHttpDataSource.Factory(httpClient)
      .setUserAgent(currentHeaders["User-Agent"] ?: DEFAULT_UA)
      .setDefaultRequestProperties(currentHeaders)
      .setTransferListener(netTransferListener)
    val dataSourceFactory = DefaultDataSource.Factory(ctx, httpFactory)
    val mediaSourceFactory = DefaultMediaSourceFactory(ctx).setDataSourceFactory(dataSourceFactory)
    val effective = effectiveDecodeMode()
    val renderers = buildRenderersFactory(ctx, effective)
    // 内存水位缓冲（与 Dart KotvBufferBudget 一致）：
    // - 只按 targetBufferBytes 刹车/续拉；播出去的样本释放后 allocated 下降即继续拉
    // - minBufferMs 刻意极大：让 DefaultLoadControl 在「未满字节预算」时始终走续拉分支，
    //   避免按剩余秒数播到快空才再缓冲
    // - 起播门槛仍用 bufferForPlayback*（短时长），与预读策略无关
    // - backBuffer=0：已播数据尽快释放，不囤回看内存
    val budget = bufferBudgetBytes(ctx)
    val loadControl: LoadControl = DefaultLoadControl.Builder()
      .setBufferDurationsMs(
        /* minBufferMs */ 3_600_000,
        /* maxBufferMs */ 3_600_000,
        /* bufferForPlaybackMs */ 1_200,
        /* bufferForPlaybackAfterRebufferMs */ 2_500,
      )
      .setTargetBufferBytes(budget)
      .setPrioritizeTimeOverSizeThresholds(false)
      .setBackBuffer(/* backBufferDurationMs */ 0, /* retainFromKeyframe */ false)
      .build()
    // 每播放器独立 BandwidthMeter，避免 getSingletonInstance 的历史码率黏住 UI
    val bandwidthMeter = DefaultBandwidthMeter.Builder(ctx).build()

    val p = ExoPlayer.Builder(ctx)
      .setMediaSourceFactory(mediaSourceFactory)
      .setRenderersFactory(renderers)
      .setLoadControl(loadControl)
      .setBandwidthMeter(bandwidthMeter)
      .build()
    player = p
    p.setVideoSurface(surface)
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
    val factory = DefaultRenderersFactory(ctx).setEnableDecoderFallback(true)
    when (mode) {
      "soft" -> {
        factory
          .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER)
          .setMediaCodecSelector(SOFT_PREFER_SELECTOR)
      }
      "hard" -> {
        // 硬解直出：只用 MediaCodec（优先 GPU 硬解）；不把视频交给 FFmpeg 扩展
        factory
          .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_OFF)
          .setMediaCodecSelector(HARD_PREFER_SELECTOR)
      }
      else -> {
        // auto：硬解优先协商；扩展仅作次选，整实例软解见 onPlayerError
        factory
          .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON)
          .setMediaCodecSelector(HARD_PREFER_SELECTOR)
      }
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

  /** 与 Dart [KotvBufferBudget] 对齐：约 15% avail 且 ≤ 总内存 5%；钳到 24–96MiB。 */
  private fun bufferBudgetBytes(ctx: Context): Int {
    return try {
      val am = ctx.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
      val mi = ActivityManager.MemoryInfo()
      am.getMemoryInfo(mi)
      var budget = (mi.totalMem * 0.05).toLong()
      if (mi.availMem > 0) {
        val byAvail = (mi.availMem * 0.15).toLong()
        if (byAvail in 1 until budget) budget = byAvail
      }
      val minB = 24L * 1024 * 1024
      val maxB = 96L * 1024 * 1024
      max(minB, min(maxB, budget)).toInt()
    } catch (_: Throwable) {
      48 * 1024 * 1024
    }
  }

  companion object {
    private const val TAG = "KotvExo"
    private const val DEFAULT_UA =
      "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"

    /** 硬解直出：优先 hardwareAccelerated；无硬解时仍交完整列表（不按编码阉割）。 */
    private val HARD_PREFER_SELECTOR = MediaCodecSelector { mimeType, requiresSecureDecoder, requiresTunnelingDecoder ->
      val infos = MediaCodecUtil.getDecoderInfos(mimeType, requiresSecureDecoder, requiresTunnelingDecoder)
      val hard = infos.filter { it.hardwareAccelerated }
      if (hard.isNotEmpty()) hard else infos
    }

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
