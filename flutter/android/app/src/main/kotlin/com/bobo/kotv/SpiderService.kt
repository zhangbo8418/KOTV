package com.bobo.kotv

import android.content.Context
import fi.iki.elonen.NanoHTTPD
import fi.iki.elonen.NanoHTTPD.IHTTPSession
import fi.iki.elonen.NanoHTTPD.Method
import fi.iki.elonen.NanoHTTPD.Response
import fi.iki.elonen.NanoHTTPD.Response.Status
import org.json.JSONObject
import java.util.Locale

/**
 * 本地 Native Service，给 Go 引擎转发 jar/py/sniff 能力。
 *
 * 约定：
 * - /jar/call : body 是 Go 侧 callJavaBridge payload（JSON 字符串），返回 SpiderBridge.call 的原样字符串
 * - /py/call  : body 是 Python call 参数，返回 result（字符串；不再返回 runner 的 JSON 封装）
 * - /sniff    : body 是 sniff 请求，返回 { "url": "...", "headers": { ... } }
 */
class SpiderService private constructor(
  context: Context,
  bindHost: String,
  bindPort: Int,
) : NanoHTTPD(bindHost, bindPort) {

  init {
    PyLoader.startIfNeeded(context)
    SnifferWebView.start(context)
    JarLoader.ensureBridgeLoaded(context)
    ThunderBridge.start(context)
  }

  override fun serve(session: IHTTPSession): Response {
    val method = session.method
    val uri = (session.uri ?: "/").lowercase(Locale.US)

    if (method == Method.GET && (uri == "/health" || uri == "/")) {
      val out = JSONObject().put("ok", true)
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
      uri != "/jar/interrupt"
    ) {
      return newJsonError(Status.BAD_REQUEST, "empty body")
    }

    return try {
      when (uri) {
        "/jar/call" -> {
          val raw = JarLoader.callBridge(body)
          json(Status.OK, raw)
        }

        "/jar/interrupt" -> {
          JarLoader.clear()
          json(Status.OK, JSONObject().put("ok", true).toString())
        }

        "/py/call" -> {
          val obj = JSONObject(body)
          val result = PyLoader.callPython(obj)
          json(Status.OK, JSONObject().put("result", result).toString())
        }

        "/sniff" -> {
          val obj = JSONObject(body)
          val resp = SnifferWebView.sniff(obj)
          json(Status.OK, resp.toString())
        }

        "/thunder/parse" -> {
          val obj = if (body.isBlank()) JSONObject() else JSONObject(body)
          json(Status.OK, ThunderBridge.parse(obj).toString())
        }

        "/thunder/fetch" -> {
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
    return post["postData"]?.trim()
      ?: post["data"]?.trim()
      ?: post.values.firstOrNull()?.trim().orEmpty()
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
    const val DefaultHost = "127.0.0.1"
    const val DefaultPort = 9979

    fun create(context: Context, host: String, port: Int): SpiderService {
      return SpiderService(context.applicationContext, host, port)
    }
  }
}

object SpiderServiceManager {
  @Volatile
  private var server: SpiderService? = null

  fun isRunning(): Boolean = server != null

  @Synchronized
  fun start(context: Context, host: String = SpiderService.DefaultHost, port: Int = SpiderService.DefaultPort) {
    if (server != null) return
    val srv = SpiderService.create(context, host, port)
    // NanoHTTPD.SOCKET_READ_TIMEOUT = 5000
    srv.start(5000, false)
    server = srv
  }

  @Synchronized
  fun stop() {
    val s = server ?: return
    try {
      s.stop()
    } catch (_: Throwable) {
      // ignore
    }
    server = null
  }
}
