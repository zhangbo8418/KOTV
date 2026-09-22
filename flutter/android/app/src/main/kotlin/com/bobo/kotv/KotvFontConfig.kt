package com.bobo.kotv

import android.util.Xml
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStream
import java.nio.charset.StandardCharsets
import org.xmlpull.v1.XmlSerializer

/**
 * 为 libass 的 fontconfig 后端写 `fonts.conf`（mpv 从 config-dir 读取并交给 ass_set_fonts）。
 *
 * 内容：系统字体目录 `/system/fonts/`、`/product/fonts/`，缓存目录，
 * 以及 serif / sans-serif / monospace 三个通用族名到系统字体的 alias。
 * 没有该文件时 fontconfig 在 Android 上找不到任何字体目录，通用族名无法解析。
 */
object KotvFontConfig {
  private const val FONTS_CONF = "fonts.conf"

  /** 已存在且非空则直接复用；写失败返回 null 并删掉半成品。 */
  @JvmStatic
  @Synchronized
  fun prepare(configDir: File, cacheDir: File): File? {
    val output = File(configDir, FONTS_CONF)
    if (output.isFile && output.length() > 0L) return output
    return try {
      configDir.mkdirs()
      cacheDir.mkdirs()
      FileOutputStream(output, false).use { writeConfig(it, cacheDir) }
      output
    } catch (_: IOException) {
      output.delete()
      null
    } catch (_: RuntimeException) {
      output.delete()
      null
    }
  }

  @Throws(IOException::class)
  private fun writeConfig(stream: OutputStream, cacheDirectory: File) {
    val s = Xml.newSerializer()
    s.setOutput(stream, StandardCharsets.UTF_8.name())
    s.startDocument(StandardCharsets.UTF_8.name(), true)
    s.startTag(null, "fontconfig")
    textTag(s, "dir", "/system/fonts/")
    textTag(s, "dir", "/product/fonts/")
    textTag(s, "cachedir", cacheDirectory.absolutePath)
    alias(s, "serif", "Noto Serif")
    alias(s, "sans-serif", "Roboto", "Noto Sans")
    alias(s, "monospace", "Droid Sans Mono")
    s.endTag(null, "fontconfig")
    s.endDocument()
    s.flush()
  }

  @Throws(IOException::class)
  private fun alias(s: XmlSerializer, family: String, vararg preferred: String) {
    s.startTag(null, "alias")
    textTag(s, "family", family)
    s.startTag(null, "prefer")
    for (p in preferred) textTag(s, "family", p)
    s.endTag(null, "prefer")
    s.endTag(null, "alias")
  }

  @Throws(IOException::class)
  private fun textTag(s: XmlSerializer, name: String, value: String) {
    s.startTag(null, name)
    s.text(value)
    s.endTag(null, name)
  }
}
