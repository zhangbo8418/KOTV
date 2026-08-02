package com.bobo.kotv

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
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit

/**
 * 对齐 TV Exo：OkHttpDataSource + Media3，带 headers / mime 提示 / 格式失败重试。
 * Flutter 侧用 Texture 渲染。
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
        main.post {
          try {
            openInternal(url, headers, mime, drm)
            result.success(true)
          } catch (t: Throwable) {
            result.error("exo_open", t.message, null)
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

    val old = player
    player = null
    old?.release()

    val httpFactory = OkHttpDataSource.Factory(httpClient)
      .setUserAgent(currentHeaders["User-Agent"] ?: DEFAULT_UA)
      .setDefaultRequestProperties(currentHeaders)
    val dataSourceFactory = DefaultDataSource.Factory(ctx, httpFactory)
    val mediaSourceFactory = DefaultMediaSourceFactory(ctx).setDataSourceFactory(dataSourceFactory)
    val renderers = DefaultRenderersFactory(ctx)
      .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER)
      .setEnableDecoderFallback(true)

    val p = ExoPlayer.Builder(ctx)
      .setMediaSourceFactory(mediaSourceFactory)
      .setRenderersFactory(renderers)
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
            ),
          )
        }
      }

      override fun onPlayerError(error: PlaybackException) {
        Log.e(TAG, "exo error code=${error.errorCode} ${error.message}", error)
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
  }

  private fun emit(payload: Map<String, Any?>) {
    main.post {
      try {
        eventSink?.success(payload)
      } catch (_: Throwable) {
      }
    }
  }

  companion object {
    private const val TAG = "KotvExo"
    private const val DEFAULT_UA =
      "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"

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
        -> MimeTypes.APPLICATION_OCTET_STREAM
        else -> null
      }
    }
  }
}
