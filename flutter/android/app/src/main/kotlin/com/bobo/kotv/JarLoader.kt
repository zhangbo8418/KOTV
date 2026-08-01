package com.bobo.kotv

import android.content.Context
import dalvik.system.DexClassLoader
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream

/**
 * 加载 `bridge/spider-bridge.jar` 并在进程内调用：
 * - SpiderBridge.call(String)
 */
object JarLoader {
  private const val BridgeClassName = "com.bobo.kotv.bridge.SpiderBridge"
  private const val BridgeAssetPath = "kotv/spider-bridge.jar"

  @Volatile
  private var bridgeCall: java.lang.reflect.Method? = null

  fun ensureBridgeLoaded(context: Context) {
    if (bridgeCall != null) return
    synchronized(this) {
      if (bridgeCall != null) return

      val jarDir = File(context.filesDir, "kotv_bridge").apply { mkdirs() }
      val jarFile = File(jarDir, "spider-bridge.jar")
      if (!jarFile.exists() || jarFile.length() == 0L) {
        copyAsset(context, BridgeAssetPath, jarFile)
      }

      val optDir = File(context.codeCacheDir, "kotv_bridge_opt").apply { mkdirs() }
      val cl = DexClassLoader(
        jarFile.absolutePath,
        optDir.absolutePath,
        null,
        context.classLoader,
      )
      val clazz = cl.loadClass(BridgeClassName)
      bridgeCall = clazz.getMethod("call", String::class.java)
    }
  }

  fun callBridge(inputJson: String): String {
    val m = bridgeCall ?: error("bridge not loaded")
    val out = m.invoke(null, inputJson)
    return out?.toString().orEmpty()
  }

  /** 换仓/中断：向 bridge 发 clear（若已加载）。 */
  fun clear() {
    try {
      if (bridgeCall == null) return
      callBridge("""{"method":"clear"}""")
    } catch (_: Throwable) {
      // ignore
    }
  }

  private fun copyAsset(context: Context, assetPath: String, destFile: File) {
    val tmp = File(destFile.absolutePath + ".tmp")
    tmp.parentFile?.mkdirs()
    context.assets.open(assetPath).use { input ->
      FileOutputStream(tmp).use { out ->
        input.copyTo(out)
      }
    }
    if (!tmp.renameTo(destFile)) {
      tmp.delete()
      error("failed to copy asset: $assetPath")
    }
  }
}

