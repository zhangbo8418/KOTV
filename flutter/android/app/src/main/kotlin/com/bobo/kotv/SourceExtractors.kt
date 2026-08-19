package com.bobo.kotv

import android.net.Uri
import android.util.Log
import com.github.catvod.net.OkHttp
import com.github.catvod.utils.Path
import com.p2p.P2PClass
import com.tvbus.engine.Listener
import com.tvbus.engine.TVCore
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.URLDecoder
import java.net.URLEncoder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * 对齐 TV Source.Extractor：荐片 P2P（libjpa）与 TVBus（运行时下载 so）。
 * Go 起播前 POST /source/fetch，把专用 scheme 转成本地 HTTP。
 */
object SourceExtractors {
  private const val TAG = "KotvSource"

  @Volatile
  private var p2p: P2PClass? = null
  @Volatile
  private var p2pPath: String? = null

  @Volatile
  private var tvcore: TVCore? = null
  @Volatile
  private var tvbusSign: String? = null

  fun match(url: String): Boolean = schemeOf(url) != Scheme.None

  fun fetch(body: JSONObject): JSONObject {
    val url = body.optString("url", "").trim()
    if (url.isEmpty()) return JSONObject().put("ok", false).put("error", "empty url")
    return try {
      val out = when (schemeOf(url)) {
        Scheme.JianPian -> fetchJianPian(url)
        Scheme.TVBus -> fetchTVBus(url, body.optJSONObject("core"))
        Scheme.None -> url
      }
      if (out.isBlank()) {
        JSONObject().put("ok", false).put("error", "empty extract url")
      } else {
        JSONObject().put("ok", true).put("url", out)
      }
    } catch (t: Throwable) {
      Log.e(TAG, "fetch failed url=$url", t)
      JSONObject().put("ok", false).put("error", t.message ?: t.toString())
    }
  }

  fun stop() {
    try {
      val p = p2p
      val path = p2pPath
      if (p != null && path != null) {
        p.P2Pdoxpause(path.toByteArray(charset("GBK")))
      }
    } catch (_: Throwable) {
    } finally {
      p2pPath = null
    }
    try {
      tvcore?.stop()
    } catch (_: Throwable) {
    }
  }

  private enum class Scheme { None, JianPian, TVBus }

  private fun schemeOf(raw: String): Scheme {
    val s = Uri.parse(raw.trim()).scheme?.lowercase().orEmpty()
    return when (s) {
      "tvbus" -> Scheme.TVBus
      "jianpian", "tvbox-xg", "xg", "xgplay" -> Scheme.JianPian
      else -> Scheme.None
    }
  }

  private fun fetchJianPian(url: String): String {
    if (p2p == null) {
      p2p = P2PClass()
    }
    val engine = p2p ?: throw IllegalStateException("libjpa 未加载")
    stopJianPianOnly()
    pruneJpaCache()
    var path = URLDecoder.decode(url, "UTF-8").split("|")[0]
    path = path.replace("jianpian://pathtype=url&path=", "")
    path = path.replace("tvbox-xg://", "").replace("tvbox-xg:", "")
    path = path.replace("xg://", "ftp://").replace("xgplay://", "ftp://")
    engine.P2Pdoxstart(path.toByteArray(charset("GBK")))
    p2pPath = path
    val encoded = URLEncoder.encode(Uri.parse(path).path ?: path, "GBK")
    return "http://127.0.0.1:${engine.port}/$encoded"
  }

  private fun stopJianPianOnly() {
    try {
      val p = p2p
      val path = p2pPath
      if (p != null && path != null) {
        p.P2Pdoxpause(path.toByteArray(charset("GBK")))
      }
    } catch (_: Throwable) {
    } finally {
      p2pPath = null
    }
  }

  private fun pruneJpaCache() {
    try {
      val dir = Path.jpa()
      val cache = dir.walkTopDown().filter { it.isFile }.sumOf { it.length() }.toDouble()
      val total = cache + dir.usableSpace.toDouble()
      if (total > 0 && cache / total * 100 > 10) {
        Path.clear(dir)
      }
    } catch (_: Throwable) {
    }
  }

  private fun fetchTVBus(url: String, core: JSONObject?): String {
    if (core == null) {
      throw IllegalStateException("tvbus 需要直播源 core（so/auth）")
    }
    val sign = core.optString("sign", "")
    if (tvcore == null || (sign.isNotEmpty() && sign != tvbusSign)) {
      tvcore?.stop()
      tvcore = null
      initTVBus(core)
      tvbusSign = sign
    }
    val latch = CountDownLatch(1)
    val hls = AtomicReference<String?>(null)
    val engine = tvcore ?: throw IllegalStateException("tvbus 未初始化")
    currentLatch = latch
    currentHls = hls
    engine.start(url)
    if (!latch.await(25, TimeUnit.SECONDS)) {
      throw IllegalStateException("tvbus 超时")
    }
    val out = hls.get()
    if (out.isNullOrBlank()) return ""
    if (out.startsWith("-")) throw IllegalStateException("tvbus 错误码 $out")
    return out
  }

  @Volatile
  private var currentLatch: CountDownLatch? = null
  @Volatile
  private var currentHls: AtomicReference<String?>? = null

  private fun initTVBus(core: JSONObject) {
    val soUrl = core.optString("so", "").trim()
    if (soUrl.isEmpty()) throw IllegalStateException("tvbus core.so 为空")
    val soPath = ensureSo(soUrl)
    val listener = object : Listener {
      override fun onInited(result: String?) {}
      override fun onStart(result: String?) {}
      override fun onInfo(result: String?) {}
      override fun onQuit(result: String?) {}
      override fun onPrepared(result: String?) {
        try {
          val json = JSONObject(result ?: "{}")
          if (!json.has("hls")) return
          currentHls?.set(json.optString("hls"))
          currentLatch?.countDown()
        } catch (t: Throwable) {
          Log.w(TAG, "tvbus onPrepared", t)
        }
      }
      override fun onStop(result: String?) {
        try {
          val json = JSONObject(result ?: "{}")
          val errno = json.optString("errno")
          if (errno.startsWith("-")) {
            currentHls?.set(errno)
            currentLatch?.countDown()
          }
        } catch (_: Throwable) {
        }
      }
    }
    val coreEngine = TVCore(soPath).listener(listener)
      .auth(resolveMaybeHttp(core.optString("auth")))
      .name(resolveMaybeHttp(core.optString("name")))
      .pass(resolveMaybeHttp(core.optString("pass")))
      .domain(resolveMaybeHttp(core.optString("domain")))
      .broker(core.optString("broker"))
    val options = core.optJSONArray("option") ?: JSONArray()
    for (i in 0 until options.length()) {
      val opt = options.optJSONObject(i) ?: continue
      val key = opt.optString("key")
      val values = opt.optJSONArray("values") ?: JSONArray()
      val list = ArrayList<String>(values.length())
      for (j in 0 until values.length()) list.add(values.optString(j))
      coreEngine.option(key, list)
    }
    coreEngine.serv(0).play(8902).mode(1).init()
    tvcore = coreEngine
  }

  private fun resolveMaybeHttp(raw: String): String {
    val v = raw.trim()
    if (v.startsWith("http://") || v.startsWith("https://")) {
      val body = OkHttp.string(v)
      return body.ifBlank { v }
    }
    return v
  }

  private fun ensureSo(url: String): String {
    if (url.isBlank()) throw IllegalArgumentException("tvbus so url 为空")
    val name = Uri.parse(url).lastPathSegment ?: "tvbus.so"
    val dest = File(Path.so(), name)
    if (Path.exists(dest)) return dest.absolutePath
    val bytes = OkHttp.client().newCall(
      okhttp3.Request.Builder().url(url).build()
    ).execute().use { resp ->
      if (!resp.isSuccessful) {
        throw IllegalStateException("下载 tvbus so HTTP ${resp.code}")
      }
      resp.body.bytes()
    }
    Path.write(dest, bytes)
    return dest.absolutePath
  }
}
