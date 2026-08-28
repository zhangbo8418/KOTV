package com.bobo.kotv

import android.content.Context
import android.util.Log
import fi.iki.elonen.NanoHTTPD
import fi.iki.elonen.NanoHTTPD.IHTTPSession
import fi.iki.elonen.NanoHTTPD.Method
import fi.iki.elonen.NanoHTTPD.Response
import fi.iki.elonen.NanoHTTPD.Response.Status
import org.json.JSONObject
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.ThreadFactory
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/**
 * 本地 Native Service，给 Go 引擎转发 jar/py/sniff 能力。
 *
 * 约定：
 * - /jar/call : body 是 Go 侧 callJavaBridge payload（JSON 字符串），返回 SpiderBridge.call 的原样字符串
 * - /py/call  : body 是 Python call 参数，返回 result（字符串；不再返回 runner 的 JSON 封装）
 * - /sniff    : body 是 sniff 请求，返回 { "url": "...", "headers": { ... } }
 *
 * 重要：先 bind :9979，再后台 warm-up。任一组件初始化失败不得阻止服务监听。
 */
class SpiderService private constructor(
  private val appContext: Context,
  bindHost: String,
  bindPort: Int,
) : NanoHTTPD(bindHost, bindPort) {

  private val warmed = AtomicBoolean(false)

  /**
   * NanoHTTPD 默认每请求 new Thread；在 Android 7 上 stop/崩溃时易触发
   * `Thread starting during runtime shutdown` 并带走 Main Listener。
   * 固定池在启动时建线程，避免 accept 时再创建。
   */
  private val workerPool = Executors.newFixedThreadPool(
    4,
    object : ThreadFactory {
      private val n = AtomicInteger(0)
      override fun newThread(r: Runnable): Thread =
        Thread(r, "kotv-spider-http-${n.incrementAndGet()}").apply { isDaemon = true }
    },
  )

  private val asyncRunner = object : AsyncRunner {
    override fun exec(clientHandler: ClientHandler?) {
      if (clientHandler == null) return
      try {
        workerPool.execute(clientHandler)
      } catch (_: Throwable) {
        // 进程退出/shutdown 时直接在当前线程处理，避免 InternalError 杀进程
        try {
          clientHandler.run()
        } catch (_: Throwable) {
        }
      }
    }

    override fun closeAll() {
      workerPool.shutdownNow()
    }

    override fun closed(clientHandler: ClientHandler?) {
      // no-op
    }
  }

  override fun getAsyncRunner(): AsyncRunner = asyncRunner

  fun warmUpAsync() {
    if (!warmed.compareAndSet(false, true)) return
    thread(name = "kotv-spider-warmup", isDaemon = true) {
      try {
        com.github.catvod.Init.set(appContext)
      } catch (t: Throwable) {
        Log.w(TAG, "Init.set failed", t)
      }
      warmUpOne("sniffer") { SnifferWebView.start(appContext) }
      warmUpOne("jar") { JarLoader.ensureBridgeLoaded(appContext) }
      warmUpOne("python") { PyLoader.startIfNeeded(appContext) }
      // 对齐 TV：不预热 XLTaskHelper/loadLibrary；仅确保 Init（Application 已 set）
      warmUpOne("thunder-init") { ThunderBridge.start(appContext) }
      Log.i(TAG, "warmup done")
    }
  }

  private fun warmUpOne(name: String, block: () -> Unit) {
    try {
      block()
      Log.i(TAG, "warmup ok: $name")
    } catch (t: Throwable) {
      Log.e(TAG, "warmup failed: $name", t)
    }
  }

  override fun serve(session: IHTTPSession): Response {
    val method = session.method
    val uri = (session.uri ?: "/").lowercase(Locale.US)

    if (method == Method.GET && (uri == "/health" || uri == "/")) {
      val out = JSONObject()
        .put("ok", true)
        .put("jar", JarLoader.isLoaded())
        .put("quickjs", JarLoader.isQuickJsNativeLoaded())
        .put("python", PyLoader.isStarted())
      return json(Status.OK, out.toString())
    }

    if (method != Method.POST) {
      return newJsonError(Status.METHOD_NOT_ALLOWED, "POST required")
    }

    val body = readRequestBody(session)
    // progress / clear / interrupt 允许空 body
    if (body.isBlank() &&
      uri != "/thunder/progress" &&
      uri != "/thunder/clear" &&
      uri != "/source/stop" &&
      uri != "/jar/interrupt" &&
      uri != "/jar/cancel" &&
      uri != "/py/interrupt"
    ) {
      return newJsonError(Status.BAD_REQUEST, "empty body")
    }

    return try {
      when (uri) {
        "/jar/call" -> {
          JarLoader.ensureBridgeLoaded(appContext)
          val raw = JarLoader.callBridge(body)
          if (raw.isBlank()) {
            return newJsonError(Status.INTERNAL_ERROR, "jar call empty response")
          }
          json(Status.OK, raw)
        }

        "/jar/interrupt" -> {
          JarLoader.clear()
          PyLoader.clearSessions()
          json(Status.OK, JSONObject().put("ok", true).toString())
        }

        "/jar/cancel" -> {
          // 软取消：按 clientId 取消 OkHttp，不 clear ClassLoader。
          JarLoader.ensureBridgeLoaded(appContext)
          val cid = try {
            if (body.isBlank()) "" else JSONObject(body).optString("clientId", "")
          } catch (_: Throwable) {
            ""
          }
          val payload = JSONObject()
            .put("method", "cancelClient")
            .put("args", JSONObject().put("clientId", cid))
            .put("clientId", cid)
            .toString()
          JarLoader.callBridge(payload)
          json(Status.OK, JSONObject().put("ok", true).toString())
        }

        "/py/interrupt" -> {
          PyLoader.clearSessions()
          json(Status.OK, JSONObject().put("ok", true).toString())
        }

        "/py/call" -> {
          PyLoader.startIfNeeded(appContext)
          val obj = JSONObject(body)
          val result = PyLoader.callPython(obj)
          // 空结果也回包装，避免 Go 侧当成 transport 失败
          val payload = JSONObject().put("result", result ?: "")
          json(Status.OK, payload.toString())
        }

        "/sniff" -> {
          SnifferWebView.start(appContext)
          val obj = JSONObject(body)
          val resp = SnifferWebView.sniff(obj)
          json(Status.OK, resp.toString())
        }

        "/source/fetch" -> {
          val obj = if (body.isBlank()) JSONObject() else JSONObject(body)
          json(Status.OK, SourceExtractors.fetch(obj).toString())
        }

        "/source/stop" -> {
          SourceExtractors.stop()
          json(Status.OK, JSONObject().put("ok", true).toString())
        }

        "/thunder/parse" -> {
          ThunderBridge.start(appContext)
          val obj = if (body.isBlank()) JSONObject() else JSONObject(body)
          json(Status.OK, ThunderBridge.parse(obj).toString())
        }

        "/thunder/fetch" -> {
          ThunderBridge.start(appContext)
          val obj = if (body.isBlank()) JSONObject() else JSONObject(body)
          json(Status.OK, ThunderBridge.fetch(obj).toString())
        }

        "/thunder/progress" -> {
          json(Status.OK, ThunderBridge.progress().toString())
        }

        "/thunder/clear" -> {
          json(Status.OK, ThunderBridge.clear().toString())
        }

        else -> newJsonError(Status.NOT_FOUND, "unknown route: $uri")
      }
    } catch (t: Throwable) {
      newJsonError(Status.INTERNAL_ERROR, t.message ?: t.toString())
    }
  }

  private fun readRequestBody(session: IHTTPSession): String {
    val post = HashMap<String, String>(8)
    try {
      session.parseBody(post)
    } catch (_: Throwable) {
      // ignore
    }
    val fromMap = post["postData"]?.trim()
      ?: post["data"]?.trim()
      ?: post.values.firstOrNull()?.trim().orEmpty()
    if (fromMap.isNotEmpty()) return fromMap

    // 部分 ROM / content-type 下 postData 为空：按 content-length 读原始流
    val len = session.headers["content-length"]?.toIntOrNull() ?: 0
    if (len <= 0 || len > 2 * 1024 * 1024) return ""
    return try {
      val buf = ByteArray(len)
      var off = 0
      val ins = session.inputStream
      while (off < len) {
        val n = ins.read(buf, off, len - off)
        if (n < 0) break
        off += n
      }
      String(buf, 0, off, Charsets.UTF_8).trim()
    } catch (_: Throwable) {
      ""
    }
  }

  private fun json(status: Status, body: String): Response {
    return newFixedLengthResponse(status, "application/json; charset=utf-8", body)
  }

  private fun newJsonError(status: Status, message: String): Response {
    val out = JSONObject()
      .put("ok", false)
      .put("error", message)
    return json(status, out.toString())
  }

  companion object {
    private const val TAG = "KotvSpiderService"
    const val DefaultHost = "127.0.0.1"
    const val DefaultPort = 9979

    fun create(context: Context, host: String, port: Int): SpiderService {
      return SpiderService(context.applicationContext, host, port)
    }
  }
}

object SpiderServiceManager {
  private const val TAG = "KotvSpiderService"

  @Volatile
  private var server: SpiderService? = null

  fun isRunning(): Boolean = server != null

  @Synchronized
  fun start(context: Context, host: String = SpiderService.DefaultHost, port: Int = SpiderService.DefaultPort) {
    if (server != null) return
    try {
      val srv = SpiderService.create(context, host, port)
      // NanoHTTPD.SOCKET_READ_TIMEOUT = 5000；daemon=false 避免进程空闲被回收
      srv.start(5000, false)
      server = srv
      srv.warmUpAsync()
      Log.i(TAG, "listening on $host:$port")
    } catch (t: Throwable) {
      Log.e(TAG, "start failed", t)
      server = null
      throw t
    }
  }

  @Synchronized
  fun stop() {
    val s = server ?: return
    server = null
    try {
      s.stop()
    } catch (_: Throwable) {
      // ignore
    }
  }
}
