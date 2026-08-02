package com.bobo.kotv

import android.content.Context
import android.util.Log
import com.android.dx.command.dexer.Main
import java.io.File
import java.util.zip.ZipFile

/**
 * 把仅含 .class 的 JVM 站点 jar 转成含 classes.dex 的 jar（ART DexClassLoader 可加载）。
 * 必须在 App ClassLoader 内调用（dalvik-dx 是 app 依赖，bridge DexCL 里 Class.forName 会找不到）。
 */
object JarDexer {
  private const val TAG = "KotvJarDexer"

  @JvmStatic
  fun ensureSiteDexJar(context: Context, srcPath: String): String {
    val src = File(srcPath)
    if (!src.isFile || src.length() == 0L) {
      error("site jar missing: $srcPath")
    }
    val codeCache = context.codeCacheDir
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
