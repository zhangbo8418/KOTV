package com.bobo.kotv

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.ByteArrayInputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.LinkedHashSet
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import java.util.regex.Pattern

/**
 * ads 阻断、rules.script/click、嵌套 player、isVideoFormat。
 */
object SnifferWebView {
  private const val TAG = "KotvSnifferWebView"

  private val mediaURLRe = Regex("(?i)https?://[^\\s\"'<>\\\\]+?\\.(?:m3u8|mp4|mkv|flv|ts|mpd)(?:\\?[^\\s\"'<>\\\\]*)?")
  private val snifferRe = Regex(
    "(?i)https?://[^\\s]{12,}\\.(?:m3u8|mp4|mkv|flv|mp3|m4a|aac|mpd)(?:\\?.*)?|https?://.*?video/tos[^\\s]*|rtmp:[^\\s]+"
  )
  private val playerRe = Pattern.compile("(?i)player.*https?://")
  private const val MAX_NESTED = 5

  @Volatile
  private var appContext: Context? = null

  private data class Rule(
    val hosts: List<String>,
    val regex: List<String>,
    val script: List<String>,
    val exclude: List<String>,
  )

  private class Session(
    val found: AtomicReference<String?>,
    val outHeaders: JSONObject,
    val done: AtomicBoolean,
    val latch: CountDownLatch,
    val ads: List<String>,
    val rules: List<Rule>,
    val click: String,
    val timeoutMs: Long,
  ) {
    val nestedUrls = LinkedHashSet<String>()
  }

  fun start(context: Context) {
    appContext = context.applicationContext
  }

  /** WebView 不可用时不建实例，避免主线程 FATAL。 */
  private fun webViewSupported(context: Context): Boolean {
    return try {
      CookieManager.getInstance()
      context.packageManager.hasSystemFeature(PackageManager.FEATURE_WEBVIEW)
    } catch (_: Throwable) {
      false
    }
  }

  fun sniff(req: JSONObject): JSONObject {
    val pageUrl = req.optString("url", "").trim()
    val html = req.optString("html", "").trim()
    val headers = req.optJSONObject("headers")
    val timeoutMs = req.optLong("timeoutMs", 15000L).coerceAtLeast(1000L)
    val click = req.optString("click", "").trim()
    val detect = req.optBoolean("detect", true)
    val ads = jsonStringList(req.optJSONArray("ads"))
    val rules = jsonRules(req.optJSONArray("rules"))

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
          webViewSniff(ctx, pageUrl, headers, timeoutMs, click, rules, ads, detect, foundHeaders)
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

  private fun httpGet(url: String, headers: JSONObject?, timeoutMs: Long): String {
    val conn = (URL(url).openConnection() as HttpURLConnection).apply {
      connectTimeout = timeoutMs.toInt()
      readTimeout = timeoutMs.toInt()
      instanceFollowRedirects = true
      requestMethod = "GET"
    }
    headers?.let {
      val keys = it.keys()
      while (keys.hasNext()) {
        val k = keys.next()
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
    click: String,
    rules: List<Rule>,
    ads: List<String>,
    detect: Boolean,
    outHeaders: JSONObject,
  ): String {
    val latch = CountDownLatch(1)
    val found = AtomicReference<String?>(null)
    val done = AtomicBoolean(false)
    val session = Session(found, outHeaders, done, latch, ads, rules, click, timeoutMs)
    val handler = Handler(Looper.getMainLooper())

    if (!webViewSupported(context)) {
      Log.w(TAG, "WebView unavailable, skip sniff for $pageUrl")
      done.set(true)
      latch.countDown()
    } else {
      handler.post {
        try {
          startWebView(context, handler, session, pageUrl, headers, detect)
        } catch (t: Throwable) {
          Log.w(TAG, "WebView sniff failed", t)
          if (done.compareAndSet(false, true)) {
            latch.countDown()
          }
        }
      }
    }
    handler.postDelayed({
      if (done.compareAndSet(false, true)) {
        latch.countDown()
      }
    }, timeoutMs)

    latch.await(timeoutMs + 1500, TimeUnit.MILLISECONDS)
    return found.get()?.let { trimUrl(it) }.orEmpty()
  }

  @SuppressLint("SetJavaScriptEnabled")
  private fun startWebView(
    context: Context,
    handler: Handler,
    session: Session,
    pageUrl: String,
    headers: JSONObject?,
    detect: Boolean,
  ) {
    val webView = WebView(context)
    val empty = WebResourceResponse("text/plain", "utf-8", ByteArrayInputStream(ByteArray(0)))
    val headerMap = HashMap<String, String>()
    headers?.let {
      val keys = it.keys()
      while (keys.hasNext()) {
        val k = keys.next()
        val v = headers.optString(k, "")
        if (v.isNotEmpty()) headerMap[k] = v
      }
    }

    val settings = webView.settings
    settings.javaScriptEnabled = true
    settings.domStorageEnabled = true
    settings.databaseEnabled = true
    settings.mediaPlaybackRequiresUserGesture = false
    settings.mixedContentMode = WebSettings.MIXED_CONTENT_ALWAYS_ALLOW
    settings.javaScriptCanOpenWindowsAutomatically = false

    headerMap.entries.firstOrNull { it.key.equals("User-Agent", true) }?.value?.let {
      settings.userAgentString = it
    }
    headerMap.entries.firstOrNull { it.key.equals("Cookie", true) }?.value?.let { cookie ->
      CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true)
      CookieManager.getInstance().setCookie(pageUrl, cookie)
    }

    webView.webViewClient = object : WebViewClient() {
      override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): WebResourceResponse? {
        val uri = request?.url ?: return super.shouldInterceptRequest(view, request)
        val url = uri.toString().trim()
        val host = uri.host.orEmpty()
        if (host.isEmpty() || isAd(host, session.ads)) {
          return empty
        }
        val reqHeaders = request.requestHeaders
        if (detect && playerRe.matcher(url).find() && addNested(session, url)) {
          handler.post {
            startWebView(context, handler, session, url, headersFromMap(reqHeaders), false)
          }
        } else if (isVideoFormat(url, pageUrl, detect, session.rules) && !isAdURL(url, session.ads)) {
          emit(session, url, request)
        }
        return super.shouldInterceptRequest(view, request)
      }

      override fun onPageFinished(view: WebView?, url: String?) {
        super.onPageFinished(view, url)
        if (url.isNullOrBlank() || url == "about:blank") return
        evaluateScripts(view, getScripts(url, session.click, session.rules), 0)
      }

      override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean = false
    }

    if (headerMap.isEmpty()) {
      webView.loadUrl(pageUrl)
    } else {
      // Cookie / UA 已单独处理；其余作额外请求头
      val extra = HashMap(headerMap)
      extra.keys.removeAll { it.equals("User-Agent", true) || it.equals("Cookie", true) }
      if (extra.isEmpty()) webView.loadUrl(pageUrl) else webView.loadUrl(pageUrl, extra)
    }

    handler.postDelayed({
      try {
        webView.stopLoading()
        webView.loadUrl("about:blank")
        webView.destroy()
      } catch (_: Throwable) {
        // ignore
      }
    }, session.timeoutMs)
  }

  private fun addNested(session: Session, url: String): Boolean {
    synchronized(session.nestedUrls) {
      if (session.nestedUrls.size >= MAX_NESTED) return false
      return session.nestedUrls.add(url)
    }
  }

  private fun emit(session: Session, url: String, request: WebResourceRequest?) {
    if (!session.found.compareAndSet(null, url)) return
    copyRequestHeaders(request, session.outHeaders)
    if (session.done.compareAndSet(false, true)) {
      session.latch.countDown()
    }
  }

  private fun evaluateScripts(view: WebView?, scripts: List<String>, index: Int) {
    if (view == null || index >= scripts.size) return
    val js = scripts[index]
    if (js.isBlank()) {
      evaluateScripts(view, scripts, index + 1)
      return
    }
    view.evaluateJavascript(js) {
      evaluateScripts(view, scripts, index + 1)
    }
  }

  private fun getScripts(pageUrl: String, click: String, rules: List<Rule>): List<String> {
    val out = ArrayList<String>()
    if (click.isNotEmpty()) out.add(click)
    val rule = matchRule(pageUrl, rules)
    for (s in rule.script) {
      val t = s.trim()
      if (t.isEmpty() || out.contains(t)) continue
      out.add(t)
    }
    return out
  }

  private fun isVideoFormat(url: String, pageUrl: String, detect: Boolean, rules: List<Rule>): Boolean {
    if (!detect && url == pageUrl) return false
    val rule = matchRule(url, rules)
    for (ex in rule.exclude) {
      val e = ex.trim()
      if (e.isEmpty()) continue
      if (url.contains(e)) return false
      runCatching { if (Pattern.compile(e).matcher(url).find()) return false }
    }
    for (rx in rule.regex) {
      val r = rx.trim()
      if (r.isEmpty()) continue
      if (url.contains(r)) return true
      runCatching { if (Pattern.compile(r).matcher(url).find()) return true }
    }
    if (url.contains("url=http") || url.contains("v=http") || url.contains(".html")) return false
    return snifferRe.containsMatchIn(url)
  }

  private fun matchRule(raw: String, rules: List<Rule>): Rule {
    if (rules.isEmpty()) return Rule(emptyList(), emptyList(), emptyList(), emptyList())
    val hosts = sniffHosts(raw)
    if (hosts.isEmpty()) return Rule(emptyList(), emptyList(), emptyList(), emptyList())
    for (rule in rules) {
      for (h in rule.hosts) {
        if (h.isNotBlank() && containOrMatch(hosts, h.trim())) return rule
      }
    }
    return Rule(emptyList(), emptyList(), emptyList(), emptyList())
  }

  /** 主 host + ?url= 内层 host，逗号拼接。 */
  private fun sniffHosts(raw: String): String {
    val uri = runCatching { Uri.parse(raw) }.getOrNull() ?: return ""
    val host = uri.host.orEmpty()
    if (host.isEmpty()) return ""
    val parts = mutableListOf(host)
    val inner = uri.getQueryParameter("url")
    if (!inner.isNullOrBlank()) {
      val ih = runCatching { Uri.parse(inner).host }.getOrNull()
      if (!ih.isNullOrBlank()) parts.add(ih)
    }
    return parts.joinToString(",")
  }

  private fun isAd(host: String, ads: List<String>): Boolean {
    val h = host.lowercase()
    for (ad in ads) {
      val a = ad.trim().lowercase()
      if (a.isNotEmpty() && containOrMatch(h, a)) return true
    }
    return false
  }

  private fun isAdURL(raw: String, ads: List<String>): Boolean {
    val host = runCatching { Uri.parse(raw).host }.getOrNull().orEmpty()
    return host.isNotEmpty() && isAd(host, ads)
  }

  /** contains 或整串 matches。 */
  private fun containOrMatch(text: String, pattern: String): Boolean {
    if (text.isEmpty() || pattern.isEmpty()) return false
    if (text.contains(pattern)) return true
    return runCatching { Pattern.compile("^(?:$pattern)$").matcher(text).matches() }.getOrDefault(false)
  }

  private fun headersFromMap(map: Map<String, String>?): JSONObject? {
    if (map.isNullOrEmpty()) return null
    val o = JSONObject()
    for ((k, v) in map) {
      if (k.isNotBlank() && v.isNotBlank()) o.put(k, v)
    }
    return if (o.length() == 0) null else o
  }

  private fun jsonStringList(arr: JSONArray?): List<String> {
    if (arr == null) return emptyList()
    val out = ArrayList<String>(arr.length())
    for (i in 0 until arr.length()) {
      val s = arr.optString(i, "").trim()
      if (s.isNotEmpty()) out.add(s)
    }
    return out
  }

  private fun jsonRules(arr: JSONArray?): List<Rule> {
    if (arr == null) return emptyList()
    val out = ArrayList<Rule>(arr.length())
    for (i in 0 until arr.length()) {
      val o = arr.optJSONObject(i) ?: continue
      out.add(
        Rule(
          hosts = jsonStringList(o.optJSONArray("hosts")),
          regex = jsonStringList(o.optJSONArray("regex")),
          script = jsonStringList(o.optJSONArray("script")),
          exclude = jsonStringList(o.optJSONArray("exclude")),
        )
      )
    }
    return out
  }
}
