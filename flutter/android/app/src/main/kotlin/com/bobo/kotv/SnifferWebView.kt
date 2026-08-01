package com.bobo.kotv

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import org.json.JSONObject
import java.io.BufferedInputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * Web 嗅探：HTTP regex + WebView 资源拦截（含请求头）。
 */
object SnifferWebView {
  private val mediaURLRe = Regex("(?i)https?://[^\\s\"'<>\\\\]+?\\.(?:m3u8|mp4|mkv|flv|ts|mpd)(?:\\?[^\\s\"'<>\\\\]*)?")
  private val snifferRe = Regex(
    "(?i)https?://[^\\s]{12,}\\.(?:m3u8|mp4|mkv|flv|mp3|m4a|aac|mpd)(?:\\?.*)?|https?://.*?video/tos[^\\s]*|rtmp:[^\\s]+"
  )

  @Volatile
  private var appContext: Context? = null

  fun start(context: Context) {
    appContext = context.applicationContext
  }

  fun sniff(req: JSONObject): JSONObject {
    val pageUrl = req.optString("url", "").trim()
    val html = req.optString("html", "").trim()
    val headers = req.optJSONObject("headers")
    val timeoutMs = req.optLong("timeoutMs", 15000L).coerceAtLeast(1000L)

    val resp = JSONObject()
    if (pageUrl.isEmpty()) {
      resp.put("url", "")
      resp.put("headers", JSONObject())
      return resp
    }

    try {
      val foundHeaders = JSONObject()
      val u = if (html.isNotEmpty()) {
        extractMedia(html)
      } else {
        val ctx = appContext
        val fromWv = if (ctx != null) {
          webViewSniff(ctx, pageUrl, headers, timeoutMs, foundHeaders)
        } else {
          ""
        }
        fromWv.ifEmpty {
          extractMedia(httpGet(pageUrl, headers, timeoutMs))
        }
      }
      resp.put("url", u)
      resp.put("headers", foundHeaders)
      return resp
    } catch (_: Throwable) {
      resp.put("url", "")
      resp.put("headers", JSONObject())
      return resp
    }
  }

  private fun extractMedia(body: String): String {
    val m1 = mediaURLRe.find(body)?.value
    if (m1 != null) return trimUrl(m1)
    val m2 = snifferRe.find(body)?.value
    return if (m2 != null) trimUrl(m2) else ""
  }

  private fun trimUrl(raw: String): String {
    return raw.trim().trimEnd(',', '"', '\'', ')', ']', '>')
  }

  private fun isMediaUrl(u: String): Boolean {
    return u.isNotEmpty() && (mediaURLRe.containsMatchIn(u) || snifferRe.containsMatchIn(u))
  }

  private fun httpGet(url: String, headers: JSONObject?, timeoutMs: Long): String {
    val conn = (URL(url).openConnection() as HttpURLConnection).apply {
      connectTimeout = timeoutMs.toInt()
      readTimeout = timeoutMs.toInt()
      instanceFollowRedirects = true
      requestMethod = "GET"
    }
    headers?.let {
      val it = it.keys()
      while (it.hasNext()) {
        val k = it.next()
        val v = headers.optString(k, "")
        if (v.isNotEmpty()) conn.setRequestProperty(k, v)
      }
    }
    conn.setRequestProperty("Accept", "*/*")

    val input = BufferedInputStream(conn.inputStream)
    return input.use {
      val bytes = it.readBytes()
      val charset = conn.contentType?.split(";")?.getOrNull(1)?.trim()?.split("=")?.getOrNull(1)
      val cs = charset?.let { c -> runCatching { java.nio.charset.Charset.forName(c) }.getOrNull() }
      String(bytes, cs ?: Charsets.UTF_8)
    }
  }

  private fun copyRequestHeaders(req: WebResourceRequest?, into: JSONObject) {
    val map = req?.requestHeaders ?: return
    for ((k, v) in map) {
      if (k.isNullOrBlank() || v.isNullOrBlank()) continue
      into.put(k, v)
    }
  }

  private fun webViewSniff(
    context: Context,
    pageUrl: String,
    headers: JSONObject?,
    timeoutMs: Long,
    outHeaders: JSONObject,
  ): String {
    val latch = CountDownLatch(1)
    val found = AtomicReference<String?>(null)
    val handler = Handler(Looper.getMainLooper())

    handler.post {
      val webView = WebView(context)
      val client = object : WebViewClient() {
        override fun onLoadResource(view: WebView?, url: String?) {
          super.onLoadResource(view, url)
          val u = url?.trim().orEmpty()
          if (isMediaUrl(u) && found.get() == null) {
            found.set(u)
            latch.countDown()
          }
        }

        override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): WebResourceResponse? {
          val u = request?.url?.toString()?.trim().orEmpty()
          if (isMediaUrl(u) && found.get() == null) {
            copyRequestHeaders(request, outHeaders)
            found.set(u)
            latch.countDown()
          }
          return super.shouldInterceptRequest(view, request)
        }
      }
      webView.webViewClient = client
      val headerMap = HashMap<String, String>()
      headers?.let {
        val it = it.keys()
        while (it.hasNext()) {
          val k = it.next()
          val v = headers.optString(k, "")
          if (v.isNotEmpty()) headerMap[k] = v
        }
      }
      webView.settings.javaScriptEnabled = true
      webView.settings.domStorageEnabled = true
      if (headerMap.isEmpty()) {
        webView.loadUrl(pageUrl)
      } else {
        webView.loadUrl(pageUrl, headerMap)
      }

      handler.postDelayed({
        try {
          webView.destroy()
        } catch (_: Throwable) {
          // ignore
        } finally {
          if (found.get() == null) latch.countDown()
        }
      }, timeoutMs)
    }

    latch.await(timeoutMs + 1500, TimeUnit.MILLISECONDS)
    return found.get()?.let { trimUrl(it) }.orEmpty()
  }
}
