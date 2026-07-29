package com.bobo.kotv

import android.content.Context
import fi.iki.elonen.NanoHTTPD
import fi.iki.elonen.NanoHTTPD.IHTTPSession
import fi.iki.elonen.NanoHTTPD.Method
import fi.iki.elonen.NanoHTTPD.Response
import fi.iki.elonen.NanoHTTPD.Status
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
  private val bindHost: String,
  private val bindPort: Int,
) : NanoHTTPD(bindHost, bindPort) {

  init {
    PyLoader.startIfNeeded(context)
    SnifferWebView.start(context)
    JarLoader.ensureBridgeLoaded(context)
  }

  override fun serve(session: IHTTPSession): Response {
    val method = session.method
    val uri = session.uri ?: "/"
    if (method != Method.POST) {
      return newJsonError(Status.METHOD_NOT_ALLOWED, "POST required")
    }

    val body = readRequestBody(session)
    if (body.isBlank()) {
      return newJsonError(Status.BAD_REQUEST, "empty body")
    }

    return try {
      when (uri.lowercase(Locale.US)) {
        "/jar/call" -> {
          // 直接把 Go payload 传给 SpiderBridge。
          val raw = JarLoader.callBridge(body)
          Response.newFixedLengthResponse(Status.OK, "application/json; charset=utf-8", raw)
        }

        "/py/call" -> {
          val obj = JSONObject(body)
          val result = PyLoader.callPython(obj)
          val out = JSONObject().put("result", result)
          Response.newFixedLengthResponse(Status.OK, "application/json; charset=utf-8", out.toString())
        }

        "/sniff" -> {
          val obj = JSONObject(body)
          val resp = SnifferWebView.sniff(obj)
          Response.newFixedLengthResponse(Status.OK, "application/json; charset=utf-8", resp.toString())
        }

        else -> newJsonError(Status.NOT_FOUND, "unknown route: $uri")
      }
    } catch (t: Throwable) {
      newJsonError(Status.INTERNAL_ERROR, t.message ?: t.toString())
    }
  }

  private fun readRequestBody(session: IHTTPSession): String {
    // NanoHTTPD：对 application/json 通常会把 raw body 放到 postData。
    val post = HashMap<String, String>(8)
    try {
      session.parseBody(post)
    } catch (_: Throwable) {
      // ignore
    }
    // 兼容可能的 key 名。
    return post["postData"]?.trim()
      ?: post["data"]?.trim()
      ?: post.values.firstOrNull()?.trim().orEmpty()
  }

  private fun newJsonError(status: Status, message: String): Response {
    val out = JSONObject()
      .put("ok", false)
      .put("error", message)
    return Response.newFixedLengthResponse(status, "application/json; charset=utf-8", out.toString())
  }

  companion object {
    const val DefaultHost = "127.0.0.1"
    const val DefaultPort = 9979
  }
}

object SpiderServiceManager {
  @Volatile
  private var server: SpiderService? = null

  fun isRunning(): Boolean = server != null

  @Synchronized
  fun start(context: Context, host: String = SpiderService.DefaultHost, port: Int = SpiderService.DefaultPort) {
    if (server != null) return
    val srv = SpiderService(context.applicationContext, host, port)
    // 在 NanoHTTPD 内部开启线程，不阻塞调用方。
    srv.start(SOCKET_READ_TIMEOUT, false)
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

