package com.bobo.kotv

import android.content.Context
import android.graphics.Color
import android.view.View
import android.widget.ImageView
import com.bumptech.glide.Glide
import com.bumptech.glide.load.model.GlideUrl
import com.bumptech.glide.load.model.LazyHeaders
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import org.json.JSONObject

/**
 * 对齐 TV [com.fongmi.android.tv.utils.ImgUtil]：
 * 解析 `url@Headers=` / `@Referer=` 等，用 Glide 拉海报。
 */
object KotvImgUtil {
  fun getUrl(raw: String?): Any? {
    var url = raw?.trim().orEmpty()
    if (url.isEmpty()) return null
    if (url.startsWith("data:")) return url
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

  /** 对齐 TV UrlUtil.convert 的常用分支（海报多为 http(s)）。 */
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
