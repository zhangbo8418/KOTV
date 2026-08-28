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

/**
 * 对齐 TV [com.fongmi.android.tv.App]：
 * - 最早 [Init.set]（attachBaseContext）
 * - 追踪前台 [Activity] 供 jar 内 Dialog / Toast / post（与 TV 一致，不隐藏 Activity）
 * - 主线程 [post] 与 jar 内 Init.post 同 Looper
 */
class KotvApplication : Application(), Application.ActivityLifecycleCallbacks {

  private val mainHandler = Handler(Looper.getMainLooper())

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
    installInitCrashGuard()
  }

  /** jar Init 偶发异常时避免进程被杀；与 TV 一样仍允许 post/Activity。 */
  private fun installInitCrashGuard() {
    val prev = Thread.getDefaultUncaughtExceptionHandler()
    Thread.setDefaultUncaughtExceptionHandler { thread, ex ->
      if (thread === mainHandler.looper.thread && isSpiderInitNoise(ex)) {
        android.util.Log.w(TAG, "ignored spider Init noise on main thread", ex)
        return@setDefaultUncaughtExceptionHandler
      }
      prev?.uncaughtException(thread, ex)
    }
  }

  private fun isSpiderInitNoise(ex: Throwable?): Boolean {
    var t = ex
    while (t != null) {
      val n = t.javaClass.name
      if (n.contains("MissingWebViewPackageException") || n.contains("AndroidRuntimeException")) {
        return true
      }
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
      UiContext.setActivity(activity)
      SpiderBridge.setAndroidActivity(activity)
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

    /** 对齐 TV App.activity()：始终返回当前前台 Activity。 */
    @JvmStatic
    fun activity(): Activity? = resumedActivity

    @JvmStatic
    fun post(runnable: Runnable) {
      instance?.mainHandler?.post(runnable)
    }

    @JvmStatic
    fun post(runnable: Runnable, delayMillis: Long) {
      val h = instance?.mainHandler ?: return
      h.removeCallbacks(runnable)
      if (delayMillis >= 0) {
        h.postDelayed(runnable, delayMillis)
      }
    }
  }
}
