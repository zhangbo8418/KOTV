package com.bobo.kotv

import android.content.Context
import android.util.Log
import dalvik.system.DexClassLoader
import java.io.File
import java.io.FileOutputStream

/**
 * 加载 `bridge/spider-bridge.jar` 并在进程内调用：
 * - SpiderBridge.call(String)
 *
 * Android 10+：可写目录里的 jar 不能作为 dex（Writable dex file is not allowed）。
 * 对齐 TV：落盘到 codeCacheDir 后 [File.setReadOnly]。
 */
object JarLoader {
  private const val TAG = "KotvJarLoader"
  private const val BridgeClassName = "com.bobo.kotv.bridge.SpiderBridge"
  private const val BridgeAssetPath = "kotv/spider-bridge.jar"

  @Volatile
  private var bridgeCall: java.lang.reflect.Method? = null

  fun isLoaded(): Boolean = bridgeCall != null

  fun ensureBridgeLoaded(context: Context) {
    if (bridgeCall != null) return
    synchronized(this) {
      if (bridgeCall != null) return

      // codeCacheDir：系统允许放优化产物；再 setReadOnly 满足 ART 限制
      val jarDir = File(context.codeCacheDir, "kotv_bridge").apply { mkdirs() }
      val jarFile = File(jarDir, "spider-bridge.jar")
      // 清掉旧版写在 filesDir 的可写 jar（会触发 Writable dex 拒绝）
      try {
        File(context.filesDir, "kotv_bridge/spider-bridge.jar").delete()
      } catch (_: Throwable) {
      }

      ensureReadonlyJar(context, jarFile)

      val optDir = File(context.codeCacheDir, "kotv_bridge_opt").apply { mkdirs() }
      val cl = DexClassLoader(
        jarFile.absolutePath,
        optDir.absolutePath,
        null,
        context.classLoader,
      )
      val clazz = cl.loadClass(BridgeClassName)
      bridgeCall = clazz.getMethod("call", String::class.java)
      Log.i(TAG, "bridge loaded: ${jarFile.absolutePath}")
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

  private fun ensureReadonlyJar(context: Context, jarFile: File) {
    // 每次进程首次加载都从 assets 刷新，并锁只读（对齐 TV JarLoader）
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
