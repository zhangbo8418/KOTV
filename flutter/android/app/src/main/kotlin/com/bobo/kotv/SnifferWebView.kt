package com.bobo.kotv

import android.content.Context
import android.os.Handler
import android.os.Looper
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
 * Web 嗅探：优先做轻量 HTTPSniff（regex 抽取媒体 URL）。
 *
 * 为了在“先跑通协议链路”的阶段快速落地，这里先不强依赖 WebView 事件流。
 * 后续如果需要“动态请求/JS 后出链路”，再把 fetch 替换成 TV 同款 WebView 拦截。
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
      val u = if (html.isNotEmpty()) {
        extractMedia(html)
      } else {
        val ctx = appContext
        if (ctx != null) {
          webViewSniff(ctx, pageUrl, headers, timeoutMs)
        } else {
          ""
        }.ifEmpty {
          extractMedia(httpGet(pageUrl, headers, timeoutMs))
        }
      }
      resp.put("url", u)
      resp.put("headers", JSONObject()) // 先不返回嗅探到的请求头
      return resp
    } catch (t: Throwable) {
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

  private fun webViewSniff(
    context: Context,
    pageUrl: String,
    headers: JSONObject?,
    timeoutMs: Long,
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
          if (u.isNotEmpty() && (mediaURLRe.containsMatchIn(u) || snifferRe.containsMatchIn(u))) {
            if (found.get() == null) {
              found.set(u)
              latch.countDown()
            }
          }
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
      // 简化：WebView 默认允许加载资源；若站点依赖 JS，可在后续按需开启。
      webView.settings.javaScriptEnabled = true
      if (headerMap.isEmpty()) {
        webView.loadUrl(pageUrl)
      } else {
        webView.loadUrl(pageUrl, headerMap)
      }

      // 超时或找到结果后清理，避免泄漏。
      handler.postDelayed({
        try {
          if (webView != null) webView.destroy()
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

