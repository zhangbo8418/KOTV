package com.bobo.kotv

import android.app.Activity
import android.app.Application
import android.content.Context
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import com.bobo.kotv.bridge.SpiderBridge
import com.bobo.kotv.host.DialogRelay
import com.bobo.kotv.host.UiContext
import com.github.catvod.Init

/**
 * 对齐 TV [com.fongmi.android.tv.App]：
 * - 最早 [Init.set]（attachBaseContext）
 * - 追踪前台 [Activity] 供 TV dex jar 内 AlertDialog / Toast
 * - 主线程 [post] 与 jar 内 Init.post 同 Looper
 */
class KotvApplication : Application(), Application.ActivityLifecycleCallbacks {

  private val mainHandler = Handler(Looper.getMainLooper())
  private var relayWm: WindowManager? = null

  override fun getSystemService(name: String): Any? {
    val raw = super.getSystemService(name)
    if (name == WINDOW_SERVICE && raw is WindowManager) {
      synchronized(this) {
        if (relayWm == null) {
          relayWm = DialogRelay.wrapWindowManager(raw)
        }
        return relayWm
      }
    }
    return raw
  }

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
    @Volatile
    private var instance: KotvApplication? = null

    @Volatile
    private var resumedActivity: Activity? = null

    @JvmStatic
    fun get(): KotvApplication? = instance

    /** 对齐 TV App.activity()：当前 resumed Activity，无则 null。 */
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
