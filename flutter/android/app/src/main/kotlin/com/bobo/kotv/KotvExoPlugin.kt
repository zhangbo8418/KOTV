package com.bobo.kotv

import android.app.ActivityManager
import android.content.Context
import android.net.Uri
import android.graphics.SurfaceTexture
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import io.flutter.view.TextureRegistry
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi
import androidx.media3.common.util.Util
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
import androidx.media3.exoplayer.trackselection.DecodeTrackSelector
import androidx.media3.exoplayer.upstream.DefaultBandwidthMeter
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.media3.extractor.ts.TsExtractor
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import okhttp3.OkHttpClient
import java.io.File
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.max
import kotlin.math.min

/**
 * OkHttpDataSource + Media3：headers / mime / DRM / 软硬解。
 *
 * 画面路径：
 * - Surface（默认）：Hybrid Composition [SurfaceView]，硬解 HDR 直出
 * - Texture（兼容）：Flutter [TextureRegistry]（部分 HDR/10bit 会花屏，仅作回退）
 * 勿再因 API&lt;26 强制 Texture：RK 盒上 Flutter Texture + HDR 呈绿条花屏。
 *
 * 软硬解（DecodeTrackSelector + ExoUtil）：
 * - hard：视频 MediaCodec 硬解优先；音轨 MediaCodec 优先、FFmpeg（AV3A）可回退
 * - auto：同 hard；解码失败再整实例软解重建一次
 * - soft：音轨强制 FFmpeg；视频仍走 MediaCodec（KOTV 无 FfmpegVideoRenderer）+ 软件解码器优先
 *
 * Media3 须为 FongMi 完整产物（scripts/build-fongmi-media3.sh 覆盖 webhtv 残缺 AAR）。
 */
@OptIn(UnstableApi::class)
class KotvExoPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

  private var channel: MethodChannel? = null
  private var events: EventChannel? = null
  private var eventSink: EventChannel.EventSink? = null
  private var appContext: Context? = null

  private var textureRegistry: TextureRegistry? = null
  private var flutterTexture: TextureRegistry.SurfaceTextureEntry? = null
  private var flutterSurface: Surface? = null
  /** true：Dart 用 Texture()（兼容模式）。默认 false=SurfaceView HDR。 */
  private var useFlutterTexture: Boolean = false
  private var surfaceHost: KotvExoSurfaceHost? = null
  /** 已绑定的 SurfaceView；全屏改尺寸时复用，避免反复 setVideoSurfaceView。 */
  private var boundSurfaceView: SurfaceView? = null
  private var player: ExoPlayer? = null
  private var trackSelector: DecodeTrackSelector? = null
  /** 可热更新默认请求头；换集复用 Player 时改这里，可热更新默认请求头，含 RequestMetadata 与工厂头。 */
  private var httpFactory: OkHttpDataSource.Factory? = null
  private var playerListener: Player.Listener? = null
  /** 当前实例创建时的直播/解码配置；变化才整机重建（仅在配置变化时重建）。 */
  private var playerBuiltLive: Boolean? = null
  private var playerBuiltDecode: String? = null
  private var playerBuiltDrmKey: String? = null
  private var currentUrl: String = ""
  private var currentHeaders: Map<String, String> = emptyMap()
  private var currentMime: String? = null
  private var currentDrm: Map<String, Any?>? = null
  private var formatRetried = false
  /** auto | soft | hard；硬/自动优先 MediaCodec 硬解直出。 */
  private var decodeMode: String = "auto"
  /** false=SurfaceView（HDR 默认），true=Flutter Texture 兼容模式。 */
  private var renderTexture: Boolean = false
  /** contain | cover。 */
  private var videoFit: String = "contain"
  /** 直播：跳过点播 KotvBufferBudget（Exo 用默认 LoadControl）。 */
  private var livePlayback: Boolean = false
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
    textureRegistry = binding.textureRegistry
    channel = MethodChannel(binding.binaryMessenger, "kotv_exo").also {
      it.setMethodCallHandler(this)
    }
    events = EventChannel(binding.binaryMessenger, "kotv_exo/events").also {
      it.setStreamHandler(this)
    }
    binding.platformViewRegistry.registerViewFactory(
      VIEW_TYPE,
      KotvExoSurfaceFactory(this),
    )
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    releasePlayer()
    releaseFlutterTexture()
    channel?.setMethodCallHandler(null)
    channel = null
    events?.setStreamHandler(null)
    events = null
    surfaceHost = null
    textureRegistry = null
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
        val mode = call.argument<String>("render")?.trim().orEmpty()
        main.post {
          try {
            renderTexture = if (mode.isNotEmpty()) {
              resolveRenderTexture(mode)
            } else {
              renderTexture
            }
            syncOutputPath()
            val tid = if (useFlutterTexture) ensureFlutterTexture() else -1L
            Log.i(
              TAG,
              "create sdk=${Build.VERSION.SDK_INT} render=${if (renderTexture) "texture" else "surface"} " +
                "path=${if (useFlutterTexture) "flutterTexture" else "platformView"} tid=$tid",
            )
            result.success(
              mapOf(
                "ok" to 1,
                "sdkInt" to Build.VERSION.SDK_INT,
                "render" to if (renderTexture) "texture" else "surface",
                "path" to if (useFlutterTexture) "flutterTexture" else "platformView",
                "textureId" to tid,
              ),
            )
          } catch (t: Throwable) {
            result.error("exo_create", t.message, null)
          }
        }
      }
      "sdkInt" -> result.success(Build.VERSION.SDK_INT)
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
        val live = call.argument<Boolean>("live") == true
        val render = call.argument<String>("render")?.trim().orEmpty()
        main.post {
          try {
            if (mode.isNotEmpty()) {
              decodeMode = normalizeDecodeMode(mode)
            }
            if (render.isNotEmpty()) {
              renderTexture = resolveRenderTexture(render)
              syncOutputPath()
            }
            decodeFallbackTried = false
            openInternal(url, headers, mime, drm, live)
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
              openInternal(currentUrl, currentHeaders, currentMime, currentDrm, livePlayback)
            }
            result.success(true)
          } catch (t: Throwable) {
            result.error("exo_decode", t.message, null)
          }
        }
      }
      "setRenderMode" -> {
        val mode = call.argument<String>("mode")?.trim().orEmpty()
        main.post {
          try {
            renderTexture = resolveRenderTexture(mode)
            syncOutputPath()
            val tid = if (useFlutterTexture) ensureFlutterTexture() else -1L
            result.success(
              mapOf(
                "ok" to true,
                "render" to if (renderTexture) "texture" else "surface",
                "path" to if (useFlutterTexture) "flutterTexture" else "platformView",
                "textureId" to tid,
                "sdkInt" to Build.VERSION.SDK_INT,
              ),
            )
          } catch (t: Throwable) {
            result.error("exo_render", t.message, null)
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
          // 只 player.stop()，不清 MediaItems / 不拆 Surface。
          // 换集复用走 setMediaItem → prepare → play；clearMediaItems 仅服务挂起场景，不在此。
          try {
            player?.stop()
          } catch (_: Throwable) {
          }
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
      "setFit" -> {
        val fit = call.argument<String>("fit")?.trim()?.lowercase().orEmpty()
        main.post {
          videoFit = normalizeFit(fit)
          applyVideoFit()
          result.success(true)
        }
      }
      // SurfaceView Hybrid Composition 上 Flutter 叠字会重影；缓冲 UI 画在原生宿主里。
      "setBufferingUi" -> {
        val show = call.argument<Boolean>("show") == true
        val text = call.argument<String>("text") ?: "缓冲中"
        main.post {
          surfaceHost?.setBufferingUi(show, text)
          result.success(true)
        }
      }
      "setRate" -> {
        val r = (call.argument<Number>("rate")?.toFloat() ?: 1f).coerceIn(0.25f, 4f)
        main.post {
          player?.setPlaybackSpeed(r)
          result.success(true)
        }
      }
      "videoTrackCount" -> {
        main.post {
          result.success(videoTrackCandidates().size)
        }
      }
      "audioTrackCount" -> {
        main.post {
          result.success(audioTrackCount())
        }
      }
      "getAudioTracks" -> {
        main.post {
          result.success(buildTracksJson(C.TRACK_TYPE_AUDIO))
        }
      }
      "getVideoTracks" -> {
        main.post {
          result.success(buildTracksJson(C.TRACK_TYPE_VIDEO))
        }
      }
      "selectAudioTrack" -> {
        val id = call.argument<String>("id") ?: "auto"
        main.post {
          try {
            selectTrackById(C.TRACK_TYPE_AUDIO, id)
            result.success(true)
          } catch (t: Throwable) {
            result.error("exo_audio_track", t.message, null)
          }
        }
      }
      "selectVideoTrack" -> {
        val id = call.argument<String>("id")
        if (!id.isNullOrBlank() && id != "auto" && !id.startsWith("idx:")) {
          main.post {
            try {
              selectTrackById(C.TRACK_TYPE_VIDEO, id)
              result.success(true)
            } catch (t: Throwable) {
              result.error("exo_video_track", t.message, null)
            }
          }
          return
        }
        val index = call.argument<Number>("index")?.toInt() ?: 0
        main.post {
          try {
            selectVideoTrackAt(index)
            result.success(true)
          } catch (t: Throwable) {
            result.error("exo_track", t.message, null)
          }
        }
      }
      "dispose" -> {
        main.post {
          releasePlayer()
          releaseFlutterTexture()
          result.success(true)
        }
      }
      else -> result.notImplemented()
    }
  }

  internal fun attachSurfaceHost(host: KotvExoSurfaceHost) {
    if (useFlutterTexture) {
      // 老盒不走 PlatformView；若误挂了宿主也不绑 Surface，避免双输出。
      Log.w(TAG, "ignore PlatformView host (flutterTexture path)")
      return
    }
    surfaceHost = host
    host.setRender(false, ::onSurfaceReady)
    onSurfaceReady()
  }

  internal fun detachSurfaceHost(host: KotvExoSurfaceHost) {
    if (surfaceHost === host) {
      unbindPlayerOutput(host)
      host.unbind()
      surfaceHost = null
    }
  }

  /** PlatformView 进树后 surface 才可用；晚于 open() 时必须在此重绑。 */
  internal fun onSurfaceReady() {
    main.post { bindPlayerSurface() }
  }

  /** Texture → Flutter Texture（兼容）；Surface → Hybrid SurfaceView（HDR）。 */
  private fun syncOutputPath() {
    // 仅用户显式选 Texture 才走 Flutter Texture；API 级不再强制（否则 HDR 绿条）。
    val wantFlutter = renderTexture
    useFlutterTexture = wantFlutter
    if (useFlutterTexture) {
      surfaceHost?.let { unbindPlayerOutput(it) }
      ensureFlutterTexture()
      bindPlayerSurface()
    } else {
      releaseFlutterTexture()
      applyRenderToHost()
    }
  }

  private fun ensureFlutterTexture(): Long {
    flutterTexture?.let { return it.id() }
    val reg = textureRegistry ?: error("no texture registry")
    val entry = reg.createSurfaceTexture()
    // 起播前占位；收到 videoSize 后再 setDefaultBufferSize。
    entry.surfaceTexture().setDefaultBufferSize(1280, 720)
    flutterTexture = entry
    flutterSurface?.release()
    flutterSurface = Surface(entry.surfaceTexture())
    Log.i(TAG, "flutterTexture id=${entry.id()}")
    return entry.id()
  }

  private fun releaseFlutterTexture() {
    try {
      player?.clearVideoSurface()
    } catch (_: Throwable) {
    }
    try {
      flutterSurface?.release()
    } catch (_: Throwable) {
    }
    flutterSurface = null
    try {
      flutterTexture?.release()
    } catch (_: Throwable) {
    }
    flutterTexture = null
  }

  private fun resizeFlutterTexture(width: Int, height: Int) {
    val w = width.coerceAtLeast(1)
    val h = height.coerceAtLeast(1)
    try {
      flutterTexture?.surfaceTexture()?.setDefaultBufferSize(w, h)
    } catch (t: Throwable) {
      Log.w(TAG, "setDefaultBufferSize failed", t)
    }
  }

  private fun applyRenderToHost() {
    if (useFlutterTexture) return
    val host = surfaceHost ?: return
    unbindPlayerOutput(host)
    // PlatformView 路径仅 SurfaceView（Texture 已改走 Flutter Texture）。
    host.setRender(false, ::onSurfaceReady)
    bindPlayerSurface()
  }

  private fun bindPlayerSurface() {
    val p = player ?: return
    if (useFlutterTexture) {
      val s = flutterSurface ?: run {
        ensureFlutterTexture()
        flutterSurface
      } ?: return
      p.setVideoSurface(s)
      applyVideoFit()
      return
    }
    val host = surfaceHost ?: return
    val sv = host.surfaceView ?: return
    if (!canBindSurface(sv)) return
    // 已绑同一 SurfaceView：尺寸变化由系统处理，勿重复 setVideoSurfaceView。
    if (boundSurfaceView === sv) {
      applyVideoFit()
      return
    }
    p.setVideoSurfaceView(sv)
    boundSurfaceView = sv
    applyVideoFit()
  }

  private fun unbindPlayerOutput(host: KotvExoSurfaceHost) {
    val p = player ?: return
    host.surfaceView?.let { p.clearVideoSurfaceView(it) }
    host.textureView?.let { p.clearVideoTextureView(it) }
    if (boundSurfaceView === host.surfaceView) boundSurfaceView = null
  }

  private fun canBindSurface(sv: SurfaceView): Boolean {
    val surface = sv.holder.surface ?: return false
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      surface.isValid
    } else {
      true
    }
  }

  private fun applyVideoFit() {
    // 画幅由 Flutter 按视频比例给 Surface 定尺寸（SurfaceView 不吃 FittedBox 变换）。
    // 画面在 Surface 内铺满即可，避免再 SCALE 裁切把比例弄丢。
    player?.videoScalingMode = C.VIDEO_SCALING_MODE_SCALE_TO_FIT
  }

  /** DRM 指纹：变了才重建（Widevine session 等不宜热切）。 */
  private fun drmKey(drm: Map<String, Any?>?): String {
    if (drm == null) return ""
    val type = drm["type"]?.toString()?.trim().orEmpty()
    val key = drm["key"]?.toString()?.trim().orEmpty()
    return "$type|$key"
  }

  private fun openInternal(
    url: String,
    headers: Map<String, String>,
    mime: String?,
    drm: Map<String, Any?>?,
    live: Boolean = false,
  ) {
    formatRetried = false
    livePlayback = live
    currentUrl = url
    currentHeaders = normalizeHeaders(headers)
    currentMime = mime ?: guessMime(url)
    currentDrm = drm
    speedBps = 0
    speedLastBytes = -1
    speedLastAtMs = 0
    transferredBytes.set(0)

    val effective = effectiveDecodeMode()
    val nextDrmKey = drmKey(drm)
    val needRebuild =
      player == null ||
        playerBuiltLive != live ||
        playerBuiltDecode != effective ||
        playerBuiltDrmKey != nextDrmKey

    if (needRebuild) {
      rebuildPlayer(live, effective, nextDrmKey)
    } else {
      httpFactory
        ?.setUserAgent(currentHeaders["User-Agent"] ?: defaultUserAgent())
        ?.setDefaultRequestProperties(currentHeaders)
      bindPlayerSurface()
    }

    val p = player ?: error("exo player missing")
    // 同实例 setMediaItem → prepare → play。
    p.setMediaItem(buildMediaItem(url, currentMime, currentDrm, currentHeaders), true)
    p.prepare()
    p.play()
    main.removeCallbacks(tick)
    main.post(tick)
  }

  /** 首次或配置变化时创建；换集复用路径不走这里。 */
  private fun rebuildPlayer(live: Boolean, effective: String, nextDrmKey: String) {
    val ctx = appContext ?: error("no context")
    releasePlayerInstance()

    val factory = OkHttpDataSource.Factory(httpClient)
      .setUserAgent(currentHeaders["User-Agent"] ?: defaultUserAgent())
      .setDefaultRequestProperties(currentHeaders)
      .setTransferListener(netTransferListener)
    httpFactory = factory
    val dataSourceFactory = DefaultDataSource.Factory(ctx, factory)
    val extractors = DefaultExtractorsFactory()
      .setTsExtractorTimestampSearchBytes(TsExtractor.DEFAULT_TIMESTAMP_SEARCH_BYTES * 10)
    val mediaSourceFactory = DefaultMediaSourceFactory(dataSourceFactory, extractors)
    val renderers = buildRenderersFactory(ctx, effective)
    val selector = buildTrackSelector(ctx, effective)
    trackSelector = selector
    val loadControl: LoadControl? = if (live) {
      null
    } else {
      val budget = bufferBudgetBytes(ctx)
      DefaultLoadControl.Builder()
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
    }
    val bandwidthMeter = DefaultBandwidthMeter.Builder(ctx).build()
    val builder = ExoPlayer.Builder(ctx)
      .setMediaSourceFactory(mediaSourceFactory)
      .setRenderersFactory(renderers)
      .setTrackSelector(selector)
      .setBandwidthMeter(bandwidthMeter)
    if (loadControl != null) {
      builder.setLoadControl(loadControl)
    }
    val p = builder.build()
    player = p
    playerBuiltLive = live
    playerBuiltDecode = effective
    playerBuiltDrmKey = nextDrmKey
    bindPlayerSurface()
    val listener =
      object : Player.Listener {
        override fun onPlaybackStateChanged(playbackState: Int) {
          val cur = player ?: return
          if (playbackState == Player.STATE_ENDED) {
            emit(mapOf("event" to "completed"))
          }
          if (playbackState == Player.STATE_READY) {
            val f = cur.videoSize
            if (f.width > 0 && f.height > 0) {
              resizeFlutterTexture(f.width, f.height)
            }
            emit(
              mapOf(
                "event" to "ready",
                "width" to f.width,
                "height" to f.height,
                "pixelRatio" to f.pixelWidthHeightRatio,
                "durationMs" to cur.duration.coerceAtLeast(0),
                "decodeMode" to (playerBuiltDecode ?: effectiveDecodeMode()),
                "videoTrackCount" to videoTrackCandidates().size,
                "audioTrackCount" to audioTrackCount(),
              ),
            )
          }
        }

        override fun onPlayerError(error: PlaybackException) {
          val mode = playerBuiltDecode ?: effectiveDecodeMode()
          Log.e(TAG, "exo error code=${error.errorCode} mode=$mode ${error.message}", error)
          if (!formatRetried) {
            val retryMime = mimeForError(error.errorCode)
            if (retryMime != null && retryMime != currentMime) {
              formatRetried = true
              currentMime = retryMime
              try {
                val cur = player ?: return
                cur.setMediaItem(buildMediaItem(currentUrl, currentMime, currentDrm, currentHeaders), true)
                cur.prepare()
                cur.play()
                return
              } catch (t: Throwable) {
                Log.e(TAG, "exo retry failed", t)
              }
            }
          }
          if (decodeMode == "auto" && !decodeFallbackTried && isDecoderError(error.errorCode)) {
            decodeFallbackTried = true
            Log.w(TAG, "exo decoder failed → soft rebuild")
            try {
              openInternal(currentUrl, currentHeaders, currentMime, currentDrm, livePlayback)
              return
            } catch (t: Throwable) {
              Log.e(TAG, "exo soft rebuild failed", t)
            }
          }
          emit(mapOf("event" to "error", "message" to (error.message ?: error.errorCodeName)))
        }

        override fun onVideoSizeChanged(videoSize: androidx.media3.common.VideoSize) {
          if (videoSize.width > 0 && videoSize.height > 0) {
            resizeFlutterTexture(videoSize.width, videoSize.height)
          }
          emit(
            mapOf(
              "event" to "size",
              "width" to videoSize.width,
              "height" to videoSize.height,
              "pixelRatio" to videoSize.pixelWidthHeightRatio,
            ),
          )
        }
      }
    playerListener = listener
    p.addListener(listener)
  }

  private fun effectiveDecodeMode(): String {
    if (decodeMode == "auto" && decodeFallbackTried) return "soft"
    return decodeMode
  }

  /**
   * 
   * DecodeTrackSelector + forceHighestSupportedBitrate；
   * tunnel 仅 Surface（默认关，KOTV 同样默认 false）。
   */
  private fun buildTrackSelector(ctx: Context, mode: String): DecodeTrackSelector {
    val trackSelector = DecodeTrackSelector(ctx)
    val builder = trackSelector.buildUponParameters()
    builder.setForceHighestSupportedBitrate(true)
    // tunnel 仅 Surface；Texture 必须关。KOTV 默认不开启 tunnel。
    builder.setTunnelingEnabled(false)
    trackSelector.setParameters(builder.build())
    applyDecodePreferences(trackSelector, mode)
    return trackSelector
  }

  /** 设置解码偏好。
   * 解码偏好用 DecodeSetting.isAudioPrefer/isVideoPrefer；KOTV 无独立开关，
   * soft = 音视频都走 SOFTWARE（用户点「软解」的预期）。 */
  private fun applyDecodePreferences(trackSelector: DecodeTrackSelector, mode: String) {
    val soft = mode == "soft"
    val audioDecode = if (soft) C.DECODE_SOFTWARE else C.DECODE_HARDWARE
    val videoDecode = if (soft) C.DECODE_SOFTWARE else C.DECODE_HARDWARE
    trackSelector.setRendererDecodePreferences(audioDecode, videoDecode)
  }

  private fun buildRenderersFactory(ctx: Context, mode: String): DefaultRenderersFactory {
    val videoMode: Int
    val audioMode: Int
    when (mode) {
      "soft" -> {
        videoMode = DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER
        audioMode = DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER
      }
      "hard" -> {
        // 硬解视频 MediaCodec；音轨仍走 FFmpeg（AV3A）
        videoMode = DefaultRenderersFactory.EXTENSION_RENDERER_MODE_OFF
        audioMode = DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON
      }
      else -> {
        // EXTENSION_RENDERER_MODE_ON
        videoMode = DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON
        audioMode = DefaultRenderersFactory.EXTENSION_RENDERER_MODE_ON
      }
    }
    val factory = KotvFfmpegRenderersFactory(ctx, videoMode, audioMode)
    when (mode) {
      "soft" -> factory.setMediaCodecSelector(SOFT_PREFER_SELECTOR)
      else -> factory.setMediaCodecSelector(HARD_PREFER_SELECTOR)
    }
    return factory
  }

  private fun buildMediaItem(
    url: String,
    mime: String?,
    drm: Map<String, Any?>?,
    headers: Map<String, String> = emptyMap(),
  ): MediaItem {
    val b = MediaItem.Builder().setUri(playUri(url))
    val local = isLocalPlayUrl(url)
    if (!local && !mime.isNullOrBlank()) b.setMimeType(mime)
    if (local && (mime == MimeTypes.APPLICATION_M3U8 || mime == MimeTypes.APPLICATION_MPD)) {
      b.setMimeType(mime)
    }
    if (headers.isNotEmpty()) {
      val extras = Bundle()
      headers.forEach { (k, v) -> extras.putString(k, v) }
      b.setRequestMetadata(
        MediaItem.RequestMetadata.Builder()
          .setMediaUri(playUri(url))
          .setExtras(extras)
          .build(),
      )
    }
    buildDrmConfig(drm)?.let { b.setDrmConfiguration(it) }
    return b.build()
  }

  /** MediaItem DRM 配置。 */
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

  private fun releasePlayerInstance() {
    main.removeCallbacks(tick)
    surfaceHost?.setBufferingUi(false, "")
    try {
      player?.clearVideoSurface()
    } catch (_: Throwable) {
    }
    val listener = playerListener
    if (listener != null) {
      try {
        player?.removeListener(listener)
      } catch (_: Throwable) {
      }
    }
    playerListener = null
    player?.release()
    player = null
    boundSurfaceView = null
    trackSelector = null
    httpFactory = null
    playerBuiltLive = null
    playerBuiltDecode = null
    playerBuiltDrmKey = null
  }

  private fun releasePlayer() {
    releasePlayerInstance()
    currentUrl = ""
    currentHeaders = emptyMap()
    currentMime = null
    currentDrm = null
    formatRetried = false
    decodeFallbackTried = false
    // Flutter Texture 跨 open 复用；仅 dispose/detach 时 releaseFlutterTexture。
  }

  /** 全部可用视频轨，按分辨率降序（与 MPV/FVP 重选策略一致）。 */
  private fun videoTrackCandidates(): List<Pair<Tracks.Group, Int>> {
    val p = player ?: return emptyList()
    val out = ArrayList<Pair<Tracks.Group, Int>>()
    for (g in p.currentTracks.groups) {
      if (g.type != C.TRACK_TYPE_VIDEO) continue
      for (i in 0 until g.length) {
        if (g.isTrackSupported(i)) {
          out.add(g to i)
        }
      }
    }
    out.sortByDescending { (g, i) ->
      val f = g.getTrackFormat(i)
      f.width.coerceAtLeast(0) * f.height.coerceAtLeast(0)
    }
    return out
  }

  private fun audioTrackCount(): Int {
    val p = player ?: return 0
    var n = 0
    for (g in p.currentTracks.groups) {
      if (g.type != C.TRACK_TYPE_AUDIO) continue
      for (i in 0 until g.length) {
        if (g.isTrackSupported(i)) n++
      }
    }
    return n
  }

  /** 枚举可切换轨，id=g{group}:t{index}。 */
  private fun buildTracksJson(type: Int): List<Map<String, Any?>> {
    val p = player ?: return emptyList()
    val out = ArrayList<Map<String, Any?>>()
    val groups = p.currentTracks.groups
    for (gi in groups.indices) {
      val g = groups[gi]
      if (g.type != type) continue
      for (i in 0 until g.length) {
        if (!g.isTrackSupported(i)) continue
        val f = g.getTrackFormat(i)
        val id = "g$gi:t$i"
        val label = describeTrack(f, type)
        out.add(
          mapOf(
            "id" to id,
            "label" to label,
            "selected" to g.isTrackSelected(i),
            "lang" to (f.language ?: ""),
            "codecs" to (f.codecs ?: ""),
            "width" to f.width,
            "height" to f.height,
          ),
        )
      }
    }
    return out
  }

  private fun describeTrack(f: Format, type: Int): String {
    val parts = ArrayList<String>()
    f.label?.takeIf { it.isNotBlank() }?.let { parts.add(it) }
    f.language?.takeIf { it.isNotBlank() }?.let { parts.add(it) }
    f.codecs?.takeIf { it.isNotBlank() }?.let { parts.add(it) }
    if (type == C.TRACK_TYPE_VIDEO) {
      if (f.width > 0 && f.height > 0) parts.add("${f.width}x${f.height}")
      val br = f.bitrate
      if (br != Format.NO_VALUE && br > 0) parts.add("${br / 1000}kbps")
    } else if (type == C.TRACK_TYPE_AUDIO) {
      if (f.channelCount > 0) parts.add("${f.channelCount}ch")
      if (f.sampleRate > 0) parts.add("${f.sampleRate}Hz")
    }
    if (parts.isEmpty()) {
      f.sampleMimeType?.takeIf { it.isNotBlank() }?.let { parts.add(it) }
    }
    return if (parts.isEmpty()) "轨道" else parts.joinToString(" · ")
  }

  /** 按 id 覆盖该类型轨。auto=清 override。 */
  private fun selectTrackById(type: Int, id: String) {
    val sel = trackSelector ?: return
    val p = player ?: return
    if (id.isEmpty() || id == "auto") {
      sel.setParameters(
        sel.buildUponParameters()
          .clearOverridesOfType(type)
          .setTrackTypeDisabled(type, false)
          .build(),
      )
      p.play()
      return
    }
    val m = Regex("""^g(\d+):t(\d+)$""").matchEntire(id) ?: return
    val gi = m.groupValues[1].toInt()
    val ti = m.groupValues[2].toInt()
    val groups = p.currentTracks.groups
    if (gi !in groups.indices) return
    val g = groups[gi]
    if (g.type != type || ti !in 0 until g.length || !g.isTrackSupported(ti)) return
    sel.setParameters(
      sel.buildUponParameters()
        .clearOverridesOfType(type)
        .setOverrideForType(TrackSelectionOverride(g.mediaTrackGroup, ti))
        .build(),
    )
    p.play()
  }

  private fun selectVideoTrackAt(index: Int) {
    val candidates = videoTrackCandidates()
    if (candidates.isEmpty()) {
      player?.play()
      return
    }
    val i = index.coerceIn(0, candidates.lastIndex)
    val (g, trackIndex) = candidates[i]
    // 用 group 在 currentTracks 中的下标拼 id，走统一 selectTrackById。
    val groups = player?.currentTracks?.groups ?: return
    val gi = groups.indexOf(g)
    if (gi < 0) return
    selectTrackById(C.TRACK_TYPE_VIDEO, "g$gi:t$trackIndex")
  }

  private fun emit(payload: Map<String, Any?>) {
    main.post {
      try {
        eventSink?.success(payload)
      } catch (_: Throwable) {
      }
    }
  }

  /** 与 Dart [KotvBufferBudget] 一致：约 15% avail 且 ≤ 总内存 5%；钳到 24–96MiB。 */
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

  private fun defaultUserAgent(): String {
    val ctx = appContext ?: return FALLBACK_PLAY_UA
    return Util.getUserAgent(ctx, ctx.packageName)
  }

  private fun normalizeHeaders(raw: Map<String, String>): Map<String, String> {
    val out = linkedMapOf<String, String>()
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
    if (out.keys.none { it.equals("User-Agent", ignoreCase = true) }) {
      out["User-Agent"] = defaultUserAgent()
    }
    return out
  }

  companion object {
    private const val TAG = "KotvExo"
    const val VIEW_TYPE = "kotv_exo/surface"
    private const val FALLBACK_PLAY_UA =
      "com.bobo.kotv/0.1.0 (Linux;Android 13) ExoPlayerLib/1.4.1"

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

    fun normalizeFit(raw: String): String {
      return when (raw.lowercase()) {
        "cover", "zoom", "crop" -> "cover"
        else -> "contain"
      }
    }

    fun isTextureRender(raw: String): Boolean {
      return when (raw.trim().lowercase()) {
        "texture", "textureview", "1" -> true
        else -> false
      }
    }

    /** 不再因老 API 强制 Texture：Flutter Texture + Rockchip HDR 会绿条花屏。 */
    fun preferTextureOnDevice(): Boolean = false

    fun resolveRenderTexture(requested: String): Boolean {
      return if (requested.isNotEmpty()) isTextureRender(requested) else false
    }

    fun isLocalPlayUrl(url: String): Boolean {
      val t = url.trim()
      val low = t.lowercase()
      return low.startsWith("file:") || low.startsWith("content:") || t.startsWith("/")
    }

    fun playUri(url: String): Uri {
      val t = url.trim()
      val low = t.lowercase()
      if (low.startsWith("content:")) return Uri.parse(t)
      if (t.startsWith("/")) return Uri.fromFile(File(t))
      if (low.startsWith("file:")) {
        try {
          val parsed = Uri.parse(t)
          var path = parsed.path
          if (!path.isNullOrEmpty()) {
            path = URLDecoder.decode(path, StandardCharsets.UTF_8.name())
            return Uri.fromFile(File(path))
          }
        } catch (_: Throwable) {
        }
        return Uri.parse(t)
      }
      return Uri.parse(t)
    }

    fun isDecoderError(errorCode: Int): Boolean {
      return errorCode == PlaybackException.ERROR_CODE_DECODER_INIT_FAILED ||
        errorCode == PlaybackException.ERROR_CODE_DECODER_QUERY_FAILED ||
        errorCode == PlaybackException.ERROR_CODE_DECODING_FAILED ||
        errorCode == PlaybackException.ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES ||
        errorCode == PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED
    }

    fun parseCatvodHeaderBlob(blob: String): Map<String, String> {
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

    fun canonicalHeader(k: String): String {
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

internal class KotvExoSurfaceFactory(
  private val plugin: KotvExoPlugin,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
  override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
    val host = KotvExoSurfaceHost(context)
    plugin.attachSurfaceHost(host)
    return object : PlatformView {
      override fun getView(): View = host
      override fun dispose() {
        // 延后卸树：同帧 dispose + Flutter detach 易触发 _owner != null 断言。
        Handler(Looper.getMainLooper()).post {
          plugin.detachSurfaceHost(host)
        }
      }
    }
  }
}

/** 按渲染方式选择 SurfaceView（HDR）或 TextureView。 */
internal class KotvExoSurfaceHost(context: Context) : FrameLayout(context) {
  var surfaceView: SurfaceView? = null
    private set
  var textureView: TextureView? = null
    private set
  private var surfaceCallback: SurfaceHolder.Callback? = null
  private var textureListener: TextureView.SurfaceTextureListener? = null
  private var onReady: (() -> Unit)? = null
  private var useTexture = false
  private val bufferingPanel: android.widget.LinearLayout
  private val bufferingProgress: android.widget.ProgressBar
  private val bufferingText: android.widget.TextView

  init {
    setBackgroundColor(android.graphics.Color.BLACK)
    // 遥控器焦点必须留在 Flutter TvFocus，否则 Hybrid SurfaceView 吃掉 DPAD 后进得去出不来。
    isFocusable = false
    isFocusableInTouchMode = false
    descendantFocusability = ViewGroup.FOCUS_BLOCK_DESCENDANTS
    importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
    val density = resources.displayMetrics.density
    fun dp(v: Int): Int = (v * density + 0.5f).toInt()
    bufferingProgress = android.widget.ProgressBar(context).apply {
      isIndeterminate = true
      isFocusable = false
      indeterminateDrawable?.setColorFilter(
        android.graphics.Color.parseColor("#E53955"),
        android.graphics.PorterDuff.Mode.SRC_IN,
      )
      layoutParams = android.widget.LinearLayout.LayoutParams(dp(28), dp(28)).apply {
        gravity = android.view.Gravity.CENTER_HORIZONTAL
      }
    }
    bufferingText = android.widget.TextView(context).apply {
      setTextColor(android.graphics.Color.WHITE)
      textSize = 15f
      typeface = android.graphics.Typeface.DEFAULT_BOLD
      gravity = android.view.Gravity.CENTER
      setPadding(0, dp(10), 0, 0)
      isFocusable = false
      maxLines = 2
    }
    bufferingPanel = android.widget.LinearLayout(context).apply {
      orientation = android.widget.LinearLayout.VERTICAL
      gravity = android.view.Gravity.CENTER
      setPadding(dp(18), dp(14), dp(18), dp(14))
      isFocusable = false
      setBackgroundColor(android.graphics.Color.parseColor("#FF111111"))
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
        background = android.graphics.drawable.GradientDrawable().apply {
          setColor(android.graphics.Color.parseColor("#FF111111"))
          cornerRadius = 20 * density
        }
      }
      addView(bufferingProgress)
      addView(bufferingText)
      visibility = View.GONE
      elevation = 8f
    }
    addView(
      bufferingPanel,
      LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply {
        gravity = android.view.Gravity.CENTER
      },
    )
  }

  override fun onAttachedToWindow() {
    super.onAttachedToWindow()
    // Flutter PlatformViewWrapper 默认 focusable，需连父链一起关掉。
    stripPlatformViewFocus()
  }

  fun setBufferingUi(show: Boolean, text: String) {
    bufferingText.text = text.ifBlank { "缓冲中" }
    bufferingPanel.visibility = if (show) View.VISIBLE else View.GONE
    if (show) {
      bufferingPanel.bringToFront()
    }
  }

  fun setRender(texture: Boolean, onReady: () -> Unit) {
    this.onReady = onReady
    if (useTexture == texture && (surfaceView != null || textureView != null)) {
      if (texture) {
        if (textureView?.isAvailable == true) onReady()
      } else {
        onReady()
      }
      return
    }
    unbind()
    // 保留 bufferingPanel；只换视频面，避免缓冲 UI 被拆掉。
    listOfNotNull(surfaceView, textureView).forEach { removeView(it) }
    surfaceView = null
    textureView = null
    useTexture = texture
    val lp = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
      if (texture) {
      val tv = TextureView(context).apply {
        layoutParams = lp
        isFocusable = false
        isFocusableInTouchMode = false
      }
      textureView = tv
      val listener = object : TextureView.SurfaceTextureListener {
        override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
          onReady()
        }

        override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) {
          // 尺寸变化不重绑播放器，避免全屏进出闪断。
        }

        override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean = true

        override fun onSurfaceTextureUpdated(surface: SurfaceTexture) {}
      }
      textureListener = listener
      tv.surfaceTextureListener = listener
      addView(tv, 0)
      if (tv.isAvailable) onReady()
    } else {
      val sv = SurfaceView(context).apply {
        layoutParams = lp
        // Hybrid Composition 需要媒体层叠出；关了会黑屏。缓冲文案改走 Flutter 层。
        setZOrderMediaOverlay(true)
        isFocusable = false
        isFocusableInTouchMode = false
      }
      surfaceView = sv
      val cb = object : SurfaceHolder.Callback {
        override fun surfaceCreated(holder: SurfaceHolder) {
          onReady()
        }

        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
          // 全屏只改 LayoutParams 时 Surface 尺寸会变，勿反复 setVideoSurfaceView。
        }

        override fun surfaceDestroyed(holder: SurfaceHolder) {}
      }
      surfaceCallback = cb
      sv.holder.addCallback(cb)
      addView(sv, 0)
    }
    bufferingPanel.bringToFront()
  }

  fun unbind() {
    surfaceCallback?.let { surfaceView?.holder?.removeCallback(it) }
    surfaceCallback = null
    textureView?.surfaceTextureListener = null
    textureListener = null
    onReady = null
  }
}
