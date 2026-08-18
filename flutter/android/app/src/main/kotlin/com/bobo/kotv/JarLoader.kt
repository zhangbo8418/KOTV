package com.bobo.kotv

import android.app.Activity
import android.content.Context
import android.util.Log
import com.bobo.kotv.bridge.SpiderBridge

/**
 * 安卓宿主在 `:kotv-bridge` 模块（对齐 TV `:catvod`），不再 d8 桌面 spider-bridge.jar。
 *
 * 站点 jar（JarDexer / SpiderBridge）：
 * - CatVodSpider / TV dex：原文件只读 + DexClassLoader，父 = App
 * - PC JVM 瘦包：D8 后再同样加载
 *
 * QuickJS JNI 在 App CL 预加载，供 TV dex jar 的 jar 内 JS；缺库不挡 PC 瘦包。
 */
object JarLoader {
  private const val TAG = "KotvJarLoader"

  @Volatile
  private var loaded = false

  @Volatile
  private var appContext: Context? = null

  @Volatile
  private var quickJsNative = false

  fun isLoaded(): Boolean = loaded

  /** TV dex jar 的 jar 内 JS 是否已能调 QuickJS JNI。缺库不影响通用 JVM 瘦包。 */
  fun isQuickJsNativeLoaded(): Boolean = quickJsNative

  private fun syncSpiderUiContext(context: Context) {
    val act = KotvApplication.activity()
    if (act != null) {
      try {
        SpiderBridge.setAndroidActivity(act)
      } catch (_: Throwable) {
      }
      return
    }
    if (context is Activity) {
      try {
        SpiderBridge.setAndroidActivity(context)
      } catch (_: Throwable) {
      }
    }
  }

  fun ensureBridgeLoaded(context: Context) {
    if (loaded) return
    synchronized(this) {
      if (loaded) return
      val app = context.applicationContext
      appContext = app
      try {
        com.github.catvod.Init.set(app)
      } catch (t: Throwable) {
        Log.w(TAG, "Init.set failed", t)
      }
      check(JarDexer::class.java.name.isNotEmpty())
      check(com.android.tools.r8.D8::class.java.name.isNotEmpty())
      preloadQuickJsNative()
      SpiderBridge.setAndroidContext(app)
      syncSpiderUiContext(context)
      injectSiteJarHooks()
      loaded = true
      Log.i(
        TAG,
        "bridge on App CL parent=${SpiderBridge::class.java.classLoader?.javaClass?.name} " +
          "ensure=${JarDexer::class.java.name} activity=${KotvApplication.activity()?.javaClass?.simpleName}",
      )
    }
  }

  private fun preloadQuickJsNative() {
    try {
      com.whl.quickjs.android.QuickJSLoader.init()
      quickJsNative = true
      Log.i(TAG, "QuickJSLoader.init ok")
    } catch (t: Throwable) {
      quickJsNative = false
      Log.w(TAG, "QuickJSLoader.init skipped (TV jar JS helpers disabled)", t)
    }
  }

  private fun injectSiteJarHooks() {
    try {
      SpiderBridge.setSiteJarEnsureMethod(
        JarDexer::class.java.getMethod("ensureSiteDexJar", Any::class.java, String::class.java),
      )
      SpiderBridge.setSiteJarCreateLoaderMethod(
        JarDexer::class.java.getMethod(
          "createSiteClassLoader",
          Any::class.java,
          String::class.java,
          ClassLoader::class.java,
        ),
      )
      SpiderBridge.setSiteJarListMethod(
        JarDexer::class.java.getMethod("listSpiderClasses", String::class.java),
      )
    } catch (t: Throwable) {
      Log.e(TAG, "inject site Method handle failed", t)
      throw t
    }
  }

  fun callBridge(inputJson: String): String {
    if (!loaded) error("bridge not loaded")
    val ctx = appContext
    ctx?.let { c ->
      try {
        SpiderBridge.setAndroidContext(c)
      } catch (_: Throwable) {
      }
      syncSpiderUiContext(c)
      try {
        injectSiteJarHooks()
      } catch (_: Throwable) {
      }
    }
    val oldCl = Thread.currentThread().contextClassLoader
    val appCl = SpiderBridge::class.java.classLoader
    if (appCl != null) {
      Thread.currentThread().contextClassLoader = appCl
    }
    return try {
      val s = SpiderBridge.call(inputJson)?.trim().orEmpty()
      if (s.isEmpty()) {
        Log.e(TAG, "SpiderBridge.call empty input=${inputJson.take(240)}")
        return """{"error":"SpiderBridge.call returned empty"}"""
      }
      s
    } finally {
      Thread.currentThread().contextClassLoader = oldCl
    }
  }

  fun clear() {
    try {
      if (!loaded) return
      callBridge("""{"method":"clear"}""")
    } catch (_: Throwable) {
      // ignore
    }
  }
}
