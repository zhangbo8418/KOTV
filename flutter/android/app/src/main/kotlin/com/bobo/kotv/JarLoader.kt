package com.bobo.kotv

import android.content.Context
import android.util.Log
import dalvik.system.DexClassLoader
import java.io.File
import java.io.FileOutputStream
import java.lang.reflect.Method
import java.util.zip.ZipFile

/**
 * 加载 `kotv/spider-bridge.jar`（须含 classes.dex）并调用 SpiderBridge.call。
 *
 * 对齐 TV：bridge / 站点均用标准父优先 [DexClassLoader]；
 * 宿主 API（Util/OkHttp/Json…）在 bridge，站点瘦包不含这些类。
 * 站点 jar（PC/安卓同一份 JVM `.class`）经 [JarDexer]（D8）转 dex。
 */
object JarLoader {
  private const val TAG = "KotvJarLoader"
  private const val BridgeClassName = "com.bobo.kotv.bridge.SpiderBridge"
  private const val BridgeAssetPath = "kotv/spider-bridge.jar"

  @Volatile
  private var bridgeCall: Method? = null

  @Volatile
  private var bridgeClass: Class<*>? = null

  @Volatile
  private var appContext: Context? = null

  /** App CL 上解析好的 Method，R8 keep 后名称稳定。 */
  @Volatile
  private var ensureMethod: Method? = null

  fun isLoaded(): Boolean = bridgeCall != null

  fun ensureBridgeLoaded(context: Context) {
    if (bridgeCall != null) return
    synchronized(this) {
      if (bridgeCall != null) return
      appContext = context.applicationContext
      // App CL 的 Init/Path 会被站点父优先命中；尽早注入 Context。
      try {
        com.github.catvod.Init.set(appContext)
      } catch (t: Throwable) {
        Log.w(TAG, "Init.set failed", t)
      }
      check(JarDexer::class.java.name.isNotEmpty())
      check(com.android.tools.r8.D8::class.java.name.isNotEmpty())
      ensureMethod = JarDexer::class.java.getMethod(
        "ensureSiteDexJar",
        Any::class.java,
        String::class.java,
      )

      val jarDir = File(context.codeCacheDir, "kotv_bridge").apply { mkdirs() }
      val jarFile = File(jarDir, "spider-bridge.jar")
      try {
        File(context.filesDir, "kotv_bridge/spider-bridge.jar").delete()
      } catch (_: Throwable) {
      }

      ensureReadonlyJar(context, jarFile)
      requireDexEntry(jarFile)

      val optDir = File(context.codeCacheDir, "kotv_bridge_opt").apply { mkdirs() }
      // 父优先：App 与 bridge 统一 OkHttp 5.4.0；桥内自带依赖与 App 对齐
      val cl = DexClassLoader(
        jarFile.absolutePath,
        optDir.absolutePath,
        null,
        context.classLoader,
      )
      val clazz = cl.loadClass(BridgeClassName)
      bridgeClass = clazz
      try {
        clazz.getMethod("setAndroidContext", Context::class.java)
          .invoke(null, context.applicationContext)
      } catch (t: Throwable) {
        Log.w(TAG, "setAndroidContext missing/failed", t)
      }
      injectEnsure(clazz)
      bridgeCall = clazz.getMethod("call", String::class.java)
      Log.i(TAG, "bridge loaded: ${jarFile.absolutePath}; ensure=${ensureMethod?.declaringClass?.name}")
    }
  }

  private fun injectEnsure(clazz: Class<*>) {
    val ensure = ensureMethod
      ?: error("JarDexer.ensureSiteDexJar Method not resolved")
    try {
      clazz.getMethod("setSiteJarEnsureMethod", Method::class.java).invoke(null, ensure)
    } catch (t: Throwable) {
      Log.e(TAG, "inject site Method handle failed", t)
      throw t
    }
  }

  fun callBridge(inputJson: String): String {
    val m = bridgeCall ?: error("bridge not loaded")
    val clazz = bridgeClass ?: m.declaringClass
    val ctx = appContext
    ctx?.let { c ->
      try {
        clazz.getMethod("setAndroidContext", Context::class.java).invoke(null, c)
      } catch (_: Throwable) {
      }
      try {
        injectEnsure(clazz)
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
        error("SpiderBridge.call returned empty")
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
    if (jarFile.isFile && jarFile.length() > 0L) return
    jarFile.parentFile?.mkdirs()
    context.assets.open(BridgeAssetPath).use { input ->
      FileOutputStream(jarFile).use { output -> input.copyTo(output) }
    }
    jarFile.setReadOnly()
  }
}
