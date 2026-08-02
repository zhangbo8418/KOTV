package com.bobo.kotv

import android.content.Context
import android.util.Log
import com.android.dx.command.dexer.Main
import java.io.File
import java.util.zip.ZipFile

/**
 * 站点 jar 是 PC/安卓**通用**的 JVM `.class` 包（不含 dex）。
 * 本对象在 Android 上用 dalvik-dx 转成含 `classes.dex` 的 sealed jar，供 ART DexClassLoader 加载。
 * 必须在 App ClassLoader 内调用（dalvik-dx 是 app 依赖，bridge DexCL 里 Class.forName 会找不到）。
 *
 * [jarHasDex] 分支仅用于命中本机已转换缓存，或异常输入；正常站点 jar 一律走 dx。
 */
object JarDexer {
  private const val TAG = "KotvJarDexer"

  /**
   * 参数用 [Any]：bridge 反射侧可能带着 shim `android.content.Context` Class，
   * 与 App 真机 Context 不是同一类型；用 Object 签名可稳定 getMethod/invoke。
   */
  @JvmStatic
  fun ensureSiteDexJar(context: Any, srcPath: String): String {
    val ctx = context as? Context
      ?: error("ensureSiteDexJar expects android.content.Context, got ${context.javaClass.name}")
    val src = File(srcPath)
    if (!src.isFile || src.length() == 0L) {
      error("site jar missing: $srcPath")
    }
    val codeCache = ctx.codeCacheDir
    val sealedDir = File(codeCache, "kotv_site_jars").apply { mkdirs() }
    val key = md5Hex("${src.absolutePath}:${src.length()}:${src.lastModified()}")

    if (jarHasDex(src)) {
      val sealed = File(sealedDir, "$key.jar")
      if (!sealed.isFile || sealed.length() != src.length()) {
        sealCopy(src, sealed)
      }
      return sealed.absolutePath
    }

    val sealed = File(sealedDir, "$key-dx.jar")
    if (sealed.isFile && sealed.length() > 0L && jarHasDex(sealed)) {
      return sealed.absolutePath
    }

    val tmp = File(sealed.absolutePath + ".tmp")
    try {
      tmp.delete()
      sealed.delete()
    } catch (_: Throwable) {
    }

    Log.i(TAG, "dalvik-dx convert ${src.name} -> ${sealed.name}")
    val args = Main.Arguments()
    args.fileNames = arrayOf(src.absolutePath)
    args.outName = tmp.absolutePath
    args.jarOutput = true
    try {
      // 部分站点 jar 很大
      val f = args.javaClass.getField("multiDex")
      f.setBoolean(args, true)
    } catch (_: Throwable) {
    }
    try {
      val f = args.javaClass.getField("coreLibrary")
      f.setBoolean(args, true)
    } catch (_: Throwable) {
    }
    val code = Main.run(args)
    if (code != 0 || !tmp.isFile || tmp.length() == 0L || !jarHasDex(tmp)) {
      error("dalvik-dx failed code=$code for ${src.name}")
    }
    if (!tmp.renameTo(sealed)) {
      tmp.copyTo(sealed, overwrite = true)
      tmp.delete()
    }
    markReadonly(sealed)
    return sealed.absolutePath
  }

  private fun jarHasDex(jarFile: File): Boolean {
    return try {
      ZipFile(jarFile).use { zf ->
        zf.entries().asSequence().any { !it.isDirectory && it.name.startsWith("classes") && it.name.endsWith(".dex") }
      }
    } catch (_: Throwable) {
      false
    }
  }

  private fun sealCopy(src: File, sealed: File) {
    val tmp = File(sealed.absolutePath + ".tmp")
    try {
      tmp.delete()
      sealed.delete()
    } catch (_: Throwable) {
    }
    src.copyTo(tmp, overwrite = true)
    if (!tmp.renameTo(sealed)) {
      tmp.copyTo(sealed, overwrite = true)
      tmp.delete()
    }
    markReadonly(sealed)
  }

  private fun markReadonly(f: File) {
    if (f.setReadOnly()) return
    try {
      Runtime.getRuntime().exec(arrayOf("chmod", "444", f.absolutePath)).waitFor()
    } catch (_: Throwable) {
    }
  }

  private fun md5Hex(s: String): String {
    val md = java.security.MessageDigest.getInstance("MD5")
    val dig = md.digest(s.toByteArray(Charsets.UTF_8))
    return dig.joinToString("") { "%02x".format(it) }
  }
}
