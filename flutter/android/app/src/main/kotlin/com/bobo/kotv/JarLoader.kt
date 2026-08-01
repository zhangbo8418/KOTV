package com.bobo.kotv

import android.content.Context
import android.util.Log
import dalvik.system.DexClassLoader
import java.io.File
import java.io.FileOutputStream
import java.util.zip.ZipFile

/**
 * 加载 `kotv/spider-bridge.jar`（须含 classes.dex）并调用 SpiderBridge.call。
 *
 * Android ART 只能加载 dex；桌面 shadowJar 的 .class 包必须在打包期经 d8 转换。
 */
object JarLoader {
  private const val TAG = "KotvJarLoader"
  private const val BridgeClassName = "com.bobo.kotv.bridge.SpiderBridge"
  private const val BridgeAssetPath = "kotv/spider-bridge.jar"

  @Volatile
  private var bridgeCall: java.lang.reflect.Method? = null

  @Volatile
  private var appContext: Context? = null

  fun isLoaded(): Boolean = bridgeCall != null

  fun ensureBridgeLoaded(context: Context) {
    if (bridgeCall != null) return
    synchronized(this) {
      if (bridgeCall != null) return
      appContext = context.applicationContext

      val jarDir = File(context.codeCacheDir, "kotv_bridge").apply { mkdirs() }
      val jarFile = File(jarDir, "spider-bridge.jar")
      try {
        File(context.filesDir, "kotv_bridge/spider-bridge.jar").delete()
      } catch (_: Throwable) {
      }

      ensureReadonlyJar(context, jarFile)
      requireDexEntry(jarFile)

      val optDir = File(context.codeCacheDir, "kotv_bridge_opt").apply { mkdirs() }
      val cl = DexClassLoader(
        jarFile.absolutePath,
        optDir.absolutePath,
        null,
        context.classLoader,
      )
      val clazz = cl.loadClass(BridgeClassName)
      try {
        val setCtx = clazz.getMethod("setAndroidContext", Context::class.java)
        setCtx.invoke(null, context.applicationContext)
      } catch (t: Throwable) {
        Log.w(TAG, "setAndroidContext missing/failed", t)
      }
      bridgeCall = clazz.getMethod("call", String::class.java)
      Log.i(TAG, "bridge loaded: ${jarFile.absolutePath}")
    }
  }

  fun callBridge(inputJson: String): String {
    val m = bridgeCall ?: error("bridge not loaded")
    // 每次调用确保 Context（进程内可能被 GC 语义打乱时再设一次）
    appContext?.let { ctx ->
      try {
        m.declaringClass.getMethod("setAndroidContext", Context::class.java).invoke(null, ctx)
      } catch (_: Throwable) {
      }
    }
    val out = m.invoke(null, inputJson)
    return out?.toString().orEmpty()
  }

  fun clear() {
    try {
      if (bridgeCall == null) return
      callBridge("""{"method":"clear"}""")
    } catch (_: Throwable) {
      // ignore
    }
  }

  private fun requireDexEntry(jarFile: File) {
    ZipFile(jarFile).use { zf ->
      val hasDex = zf.entries().asSequence().any { !it.isDirectory && it.name.startsWith("classes") && it.name.endsWith(".dex") }
      if (!hasDex) {
        error(
          "spider-bridge.jar has no classes.dex (JVM jar cannot load on Android). " +
            "Rebuild with prepareSpiderBridgeJar / d8.",
        )
      }
    }
  }

  private fun ensureReadonlyJar(context: Context, jarFile: File) {
    if (jarFile.exists()) {
      try {
        jarFile.setWritable(true)
      } catch (_: Throwable) {
      }
      try {
        jarFile.delete()
      } catch (_: Throwable) {
      }
    }
    copyAsset(context, BridgeAssetPath, jarFile)
    if (!jarFile.setReadOnly()) {
      try {
        Runtime.getRuntime().exec(arrayOf("chmod", "444", jarFile.absolutePath)).waitFor()
      } catch (t: Throwable) {
        Log.w(TAG, "chmod 444 failed: ${jarFile.absolutePath}", t)
      }
    }
  }

  private fun copyAsset(context: Context, assetPath: String, destFile: File) {
    val tmp = File(destFile.absolutePath + ".tmp")
    tmp.parentFile?.mkdirs()
    try {
      tmp.delete()
    } catch (_: Throwable) {
    }
    context.assets.open(assetPath).use { input ->
      FileOutputStream(tmp).use { out ->
        input.copyTo(out)
      }
    }
    if (destFile.exists()) {
      try {
        destFile.delete()
      } catch (_: Throwable) {
      }
    }
    if (!tmp.renameTo(destFile)) {
      tmp.copyTo(destFile, overwrite = true)
      tmp.delete()
    }
    if (!destFile.exists() || destFile.length() == 0L) {
      error("failed to copy asset: $assetPath")
    }
  }
}
