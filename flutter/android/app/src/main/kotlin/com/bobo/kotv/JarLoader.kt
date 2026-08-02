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
      // 确保 JarDexer/dalvik-dx 被编进 APK，供 SpiderBridge 反射调用
      check(JarDexer::class.java.name.isNotEmpty())

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
      // 注入 App 侧 JarDexer：bridge DexCL 内 Class.forName 应用类会失败（红米实测）
      try {
        clazz.getMethod("setSiteJarHelper", Any::class.java).invoke(null, JarDexer)
      } catch (t: Throwable) {
        Log.e(TAG, "setSiteJarHelper failed", t)
        throw t
      }
      bridgeCall = clazz.getMethod("call", String::class.java)
      Log.i(TAG, "bridge loaded: ${jarFile.absolutePath}")
    }
  }

  fun callBridge(inputJson: String): String {
    val m = bridgeCall ?: error("bridge not loaded")
    val ctx = appContext
    ctx?.let { c ->
      try {
        m.declaringClass.getMethod("setAndroidContext", Context::class.java).invoke(null, c)
      } catch (_: Throwable) {
      }
      // 每次调用确保 helper 仍在（部分机型/热重载后静态字段可能丢）
      try {
        m.declaringClass.getMethod("setSiteJarHelper", Any::class.java).invoke(null, JarDexer)
      } catch (_: Throwable) {
      }
    }
    val oldCl = Thread.currentThread().contextClassLoader
    if (ctx != null) {
      Thread.currentThread().contextClassLoader = ctx.classLoader
    }
    return try {
      val out = m.invoke(null, inputJson)
      val s = out?.toString()?.trim().orEmpty()
      if (s.isEmpty()) {
        error("SpiderBridge.call returned empty (site jar load/init failed?)")
      }
      s
    } catch (t: java.lang.reflect.InvocationTargetException) {
      val c = t.cause ?: t
      throw RuntimeException(c.message ?: c.toString(), c)
    } finally {
      Thread.currentThread().contextClassLoader = oldCl
    }
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
