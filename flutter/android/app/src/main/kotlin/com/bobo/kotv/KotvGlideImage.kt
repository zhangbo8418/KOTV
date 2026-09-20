package com.bobo.kotv

import android.content.Context
import android.graphics.Color
import android.util.Base64
import android.view.View
import android.widget.ImageView
import com.bumptech.glide.Glide
import com.bumptech.glide.load.model.GlideUrl
import com.bumptech.glide.load.model.LazyHeaders
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.regex.Pattern

/**
 * 海报加载：
 * 解析 `url@Headers=` / `@Referer=` 等，用 Glide 拉海报。
 * data: 经 cache() 写入引擎 /image/{md5} 再以 HTTP 地址加载。
 */
object KotvImgUtil {
  private const val MAX_DATA_URI_LENGTH = 8 * 1024 * 1024
  private val IMAGE_MIME = Pattern.compile("image/[a-z0-9.+-]+")
  private val localDecoded = ConcurrentHashMap<String, Pair<String, ByteArray>>()

  fun getUrl(raw: String?): Any? {
    var url = raw?.trim().orEmpty()
    if (url.isEmpty()) return null
    if (url.regionMatches(0, "data:", 0, 5, ignoreCase = true)) {
      url = cache(url)
      if (url.isEmpty()) return null
    }
    url = convertLocal(url)
    var param: String? = null
    val builder = LazyHeaders.Builder()
    if (url.contains("@Headers=")) {
      param = url.split("@Headers=")[1].split("@")[0]
      addHeader(builder, param)
    }
    if (url.contains("@Cookie=")) {
      param = url.split("@Cookie=")[1].split("@")[0]
      builder.addHeader("Cookie", param)
    }
    if (url.contains("@Referer=")) {
      param = url.split("@Referer=")[1].split("@")[0]
      builder.addHeader("Referer", param)
    }
    if (url.contains("@User-Agent=")) {
      param = url.split("@User-Agent=")[1].split("@")[0]
      builder.addHeader("User-Agent", param)
    }
    if (param != null) {
      url = url.split("@")[0]
    }
    if (url.isEmpty()) return null
    return GlideUrl(url, builder.build())
  }

  /** ImgUtil.cache：data: → http://127.0.0.1:port/image/{md5}；其它原样。 */
  fun cache(url: String?): String {
    val u = url?.trim().orEmpty()
    if (u.isEmpty()) return ""
    if (!u.regionMatches(0, "data:", 0, 5, ignoreCase = true)) return u
    if (u.length > MAX_DATA_URI_LENGTH) return ""
    val key = md5Hex(u)
    if (key.isEmpty()) return ""
    val decoded = localDecoded.computeIfAbsent(key) {
      decodeDataURI(u) ?: return@computeIfAbsent Pair("", ByteArray(0))
    }
    if (decoded.first.isEmpty() || decoded.second.isEmpty()) {
      localDecoded.remove(key)
      return ""
    }
    val port = proxyPort()
    val address = "http://127.0.0.1:$port/image/$key"
    try {
      val conn = URL(address).openConnection() as HttpURLConnection
      conn.connectTimeout = 3000
      conn.readTimeout = 5000
      conn.requestMethod = "PUT"
      conn.doOutput = true
      conn.setRequestProperty("Content-Type", decoded.first)
      conn.outputStream.use { it.write(decoded.second) }
      conn.inputStream?.close()
      conn.errorStream?.close()
      conn.disconnect()
    } catch (_: Throwable) {
    }
    return address
  }

  private fun decodeDataURI(url: String): Pair<String, ByteArray>? {
    val comma = url.indexOf(',')
    if (comma < 0) return null
    val metadata = url.substring(5, comma).lowercase(Locale.ROOT)
    val mime = metadata.split(";", limit = 2)[0]
    if (!IMAGE_MIME.matcher(mime).matches() || !metadata.endsWith(";base64")) return null
    return try {
      val data = Base64.decode(url.substring(comma + 1), Base64.DEFAULT)
      if (data == null || data.isEmpty()) null else Pair(mime, data)
    } catch (_: IllegalArgumentException) {
      null
    }
  }

  private fun md5Hex(src: String): String {
    if (src.isEmpty()) return ""
    return try {
      val dig = MessageDigest.getInstance("MD5").digest(src.toByteArray(Charsets.UTF_8))
      dig.joinToString("") { "%02x".format(it) }
    } catch (_: Exception) {
      ""
    }
  }

  private fun proxyPort(): Int {
    return try {
      System.getProperty("kotv.proxy.port")?.toIntOrNull()
        ?: System.getenv("KOTV_PROXY_PORT")?.toIntOrNull()
        ?: 9978
    } catch (_: Throwable) {
      9978
    }
  }

  private fun addHeader(builder: LazyHeaders.Builder, header: String?) {
    if (header.isNullOrBlank()) return
    try {
      val obj = JSONObject(header)
      val keys = obj.keys()
      while (keys.hasNext()) {
        val k = keys.next()
        val v = obj.optString(k, "").trim()
        if (k.isBlank() || v.isEmpty()) continue
        builder.addHeader(fixHeader(k), v)
      }
    } catch (_: Throwable) {
    }
  }

  private fun fixHeader(key: String): String {
    return when {
      key.equals("User-Agent", ignoreCase = true) || key.equals("ua", ignoreCase = true) -> "User-Agent"
      key.equals("Referer", ignoreCase = true) || key.equals("referrer", ignoreCase = true) -> "Referer"
      key.equals("Cookie", ignoreCase = true) -> "Cookie"
      else -> key
    }
  }

  /** 海报地址常用转换分支（多为 http(s)）。 */
  private fun convertLocal(url: String): String {
    val lower = url.lowercase()
    return when {
      lower.startsWith("proxy://") -> "http://127.0.0.1:9978/proxy?" + url.substring("proxy://".length)
      lower.startsWith("file://") -> "http://127.0.0.1:9978/file/" + url.substring("file://".length)
      else -> url
    }
  }
}

class KotvGlideImageView(
  context: Context,
  url: String,
  fitCover: Boolean,
) : PlatformView {
  private val imageView =
    object : ImageView(context) {
      override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        stripPlatformViewFocus()
      }
    }.apply {
      scaleType = if (fitCover) ImageView.ScaleType.CENTER_CROP else ImageView.ScaleType.FIT_CENTER
      setBackgroundColor(Color.parseColor("#2A1848"))
      adjustViewBounds = false
      isFocusable = false
      isFocusableInTouchMode = false
      importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
    }

  init {
    val model = KotvImgUtil.getUrl(url)
    if (model == null) {
      imageView.setImageDrawable(null)
    } else {
      try {
        val req = Glide.with(imageView).load(model).dontAnimate()
        if (fitCover) {
          req.centerCrop().into(imageView)
        } else {
          req.fitCenter().into(imageView)
        }
      } catch (t: Throwable) {
        android.util.Log.w("KotvGlide", "load failed: $url", t)
      }
    }
  }

  override fun getView(): View = imageView

  override fun dispose() {
    try {
      Glide.with(imageView).clear(imageView)
    } catch (_: Throwable) {
    }
  }
}

class KotvGlideImageFactory : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
  override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
    val map = args as? Map<*, *>
    val url = map?.get("url")?.toString().orEmpty()
    val fit = map?.get("fit")?.toString()?.equals("cover", ignoreCase = true) != false
    return KotvGlideImageView(context, url, fit)
  }
}
