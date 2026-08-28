package com.bobo.kotv

import android.app.Activity
import android.app.Application
import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import com.bobo.kotv.bridge.SpiderBridge
import com.bobo.kotv.host.UiContext
import com.github.catvod.Init
import com.github.catvod.utils.Util

/**
 * 对齐 TV [com.fongmi.android.tv.App]：
 * - 最早 [Init.set]（attachBaseContext）
 * - 追踪前台 [Activity] 供 TV dex jar 内 AlertDialog / Toast
 * - 主线程 [post] 与 jar 内 Init.post 同 Looper
 */
class KotvApplication : Application(), Application.ActivityLifecycleCallbacks {

  private val mainHandler = Handler(Looper.getMainLooper())

  /** 老盒子 WebView relro 超时后，后续 jar post 一律丢弃，避免再次卡死 UI。 */
  @Volatile
  private var webViewBroken = false

  override fun attachBaseContext(base: Context) {
    super.attachBaseContext(base)
    instance = this
    try {
      Init.set(base)
    } catch (_: Throwable) {
    }
  }

  override fun onCreate() {
    super.onCreate()
    instance = this
    try {
      Init.set(this)
      UiContext.setApplication(this)
      SpiderBridge.setAndroidContext(this)
    } catch (_: Throwable) {
    }
    registerActivityLifecycleCallbacks(this)
    installWebViewCrashGuard()
  }

  /**
   * 社区 jar Init 会反射宿主 App.activity() 读 Activity 类名；非 Fongmi HomeActivity 时会弹 WebView 配置页。
   * WebView 不可用（老盒子 relro 超时）时主线程 FATAL。此处吞掉该异常，避免整 app 被杀。
   */
  private fun installWebViewCrashGuard() {
    val prev = Thread.getDefaultUncaughtExceptionHandler()
    Thread.setDefaultUncaughtExceptionHandler { thread, ex ->
      if (thread === mainHandler.looper.thread && isMissingWebView(ex)) {
        webViewBroken = true
        android.util.Log.w(TAG, "ignored MissingWebView during spider Init", ex)
        return@setDefaultUncaughtExceptionHandler
      }
      prev?.uncaughtException(thread, ex)
    }
  }

  private fun isMissingWebView(ex: Throwable?): Boolean {
    var t = ex
    while (t != null) {
      if (t.javaClass.name.contains("MissingWebViewPackageException")) return true
      t = t.cause
    }
    return false
  }

  override fun onActivityResumed(activity: Activity) {
    if (activity !== resumedActivity) {
      resumedActivity = activity
    }
    syncUiActivity(activity)
  }

  override fun onActivityPaused(activity: Activity) {
    if (activity === resumedActivity) {
      resumedActivity = null
      syncUiActivity(null)
    }
  }

  override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {
  }

  override fun onActivityStarted(activity: Activity) {
  }

  override fun onActivityStopped(activity: Activity) {
  }

  override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {
  }

  override fun onActivityDestroyed(activity: Activity) {
    if (activity === resumedActivity) {
      resumedActivity = null
      syncUiActivity(null)
    }
  }

  private fun syncUiActivity(activity: Activity?) {
    try {
      // UiContext 仍更新，供 DialogRelay；jar 侧通过 activity()/Init.activity() 读取，非 remoteUi 时返回 null。
      UiContext.setActivity(activity)
      if (Util.hasRemoteUi()) {
        SpiderBridge.setAndroidActivity(activity)
      }
    } catch (_: Throwable) {
    }
  }

  companion object {
    private const val TAG = "KotvApplication"
    @Volatile
    private var instance: KotvApplication? = null

    @Volatile
    private var resumedActivity: Activity? = null

    @JvmStatic
    fun get(): KotvApplication? = instance

    /** 对齐 TV App.activity()；非 remoteUi 时对 jar 隐藏 Activity，避免 Init 弹 WebView 配置页。 */
    @JvmStatic
    fun activity(): Activity? {
      if (!Util.hasRemoteUi()) return null
      return resumedActivity
    }

    @JvmStatic
    fun post(runnable: Runnable) {
      val app = instance ?: return
      // 非 remoteUi 宿主不需要 jar WebView 配置页；post 到主线程会卡 Flutter UI。
      if (!Util.hasRemoteUi() || app.webViewBroken) {
        android.util.Log.d(TAG, "drop jar post headless=${!Util.hasRemoteUi()} broken=${app.webViewBroken}")
        return
      }
      app.mainHandler.post(runnable)
    }

    @JvmStatic
    fun post(runnable: Runnable, delayMillis: Long) {
      val app = instance ?: return
      if (!Util.hasRemoteUi() || app.webViewBroken) {
        android.util.Log.d(TAG, "drop jar delayed post headless=${!Util.hasRemoteUi()} broken=${app.webViewBroken}")
        return
      }
      app.mainHandler.removeCallbacks(runnable)
      if (delayMillis >= 0) {
        app.mainHandler.postDelayed(runnable, delayMillis)
      }
    }
  }
}
