package com.fongmi.android.tv

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import com.bobo.kotv.bridge.SpiderBridge
import com.bobo.kotv.host.UiContext
import com.github.catvod.Init

/**
 * DexNative 用 **Application 类名** 识别安卓宿主，
 * 不能只是包名 shim。Manifest 必须指向本类，Init.init(Application) 传入的也是本类实例。
 */
class App : Application(), Application.ActivityLifecycleCallbacks {

  private val mainHandler = object : Handler(Looper.getMainLooper()) {
    override fun dispatchMessage(msg: android.os.Message) {
      val cb = msg.callback
      if (cb != null && Companion.isJarHostConfigRunnable(cb)) {
        android.util.Log.i(TAG, "skip jar host-config WebView runnable (dispatchMessage)")
        return
      }
      super.dispatchMessage(msg)
    }
  }

  override fun attachBaseContext(base: Context) {
    super.attachBaseContext(base)
    instance = this
    installInitCrashGuard()
    // Before Flutter/GPU can load system libvulkan.so: register app stub first
    // so libmpv DT_NEEDED libvulkan.so binds to our 1.1 symbol stubs (API 25).
    preloadLibcxx()
    preloadAppLibvulkan()
    try {
      Init.set(base)
    } catch (_: Throwable) {
    }
    hookGlobalMainDispatch()
  }

  private fun preloadLibcxx() {
    // jniLibs 已同步 webhtv libc++（与 libmpv/libplayer 配套）。必须走 Java
    // System.loadLibrary（ClassLoader namespace）。kotv_dl 的 dlopen 会绕过 namespace，
    // API25 上 libc++ 内部 _Znwm@plt GOT 不重定位 → setOptionString SIGSEGV(0x1423c0)。
    try {
      System.loadLibrary("c++_shared")
      android.util.Log.i(TAG, "preload libc++_shared via System.loadLibrary(jniLibs)")
    } catch (t: Throwable) {
      android.util.Log.w(TAG, "preload libc++_shared failed", t)
    }
  }

  private fun preloadAppLibvulkan() {
    // 真机 Vulkan≥1.2：清掉旧包抽出的 jniLibs stub，走系统 libvulkan。
    // API25：stub 只在 assets，由 MPVLib.ensureLoaded 再加载。
    try {
      if (`is`.xyz.mpv.MPVLib.isDeviceVulkanCapable(this)) {
        `is`.xyz.mpv.MPVLib.removeAppVulkanStubIfPresent(this)
        android.util.Log.i(TAG, "skip libvulkan stub; use system Vulkan (device ≥1.2)")
        return
      }
    } catch (t: Throwable) {
      android.util.Log.w(TAG, "Vulkan capability probe failed", t)
    }
    android.util.Log.i(TAG, "device lacks Vulkan 1.2; stub will load from assets when MPV starts")
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

  override fun getPackageName(): String {
    if (spoofFongmiPackage || callerIsSpiderJar()) return FONGMI_PACKAGE
    return super.getPackageName()
  }

  private fun callerIsSpiderJar(): Boolean {
    val st = Throwable().stackTrace
    var i = 0
    while (i < st.size && i < 16) {
      val n = st[i].className
      if (n.startsWith("com.github.catvod.spider") ||
          n.contains("merge.Ly") ||
          n.contains("DexNative") ||
          n.contains("ftyguard") ||
          n.contains("mergeguard")
      ) {
        return true
      }
      i++
    }
    return false
  }

  /** attachBaseContext 起就扫主队列，兜底 jar 里 new Handler(mainLooper).post(merge.Ly)。 */
  private fun hookGlobalMainDispatch() {
    startMergeLyGuard(60_000L)
  }

  private fun installInitCrashGuard() {
    val prev = Thread.getDefaultUncaughtExceptionHandler()
    Thread.setDefaultUncaughtExceptionHandler { thread, ex ->
      if (thread === Looper.getMainLooper().thread && isSpiderInitNoise(ex)) {
        android.util.Log.w(TAG, "ignored spider Init noise; re-enter Looper.loop()", ex)
        // dispatchMessage 抛出后 Looper.loop 已退出；不重新进入则进程随后会死掉。
        try {
          Looper.loop()
        } catch (t: Throwable) {
          if (isSpiderInitNoise(t)) {
            android.util.Log.w(TAG, "re-entered Looper hit spider noise again", t)
            try {
              Looper.loop()
            } catch (t2: Throwable) {
              prev?.uncaughtException(thread, t2)
            }
          } else {
            prev?.uncaughtException(thread, t)
          }
        }
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
    private const val TAG = "KotvApp"
    private const val FONGMI_PACKAGE = "com.fongmi.android.tv"

    @Volatile
    private var instance: App? = null

    @Volatile
    private var resumedActivity: Activity? = null

    @Volatile
    private var spoofFongmiPackage = false

    private var realPackageName: String? = null
    private var realActivityThreadPkg: String? = null

    @JvmStatic
    fun get(): App? = instance

    @JvmStatic
    fun activity(): Activity? = resumedActivity

    @JvmStatic
    fun setSpoofFongmiPackage(on: Boolean): Boolean {
      val app = instance ?: return false
      try {
        if (on) {
          if (!spoofFongmiPackage) {
            realPackageName = app.baseContext.packageName
            app.applicationInfo.packageName = FONGMI_PACKAGE
            spoofActivityThreadPackage(true)
            spoofFongmiPackage = true
            startMergeLyGuard(45_000L)
          }
        } else if (spoofFongmiPackage) {
          val real = realPackageName
          if (real != null) {
            app.applicationInfo.packageName = real
          }
          spoofActivityThreadPackage(false)
          spoofFongmiPackage = false
        }
        android.util.Log.i(TAG, "spoofFongmiPackage=$on real=$realPackageName atPkg=$realActivityThreadPkg appClass=${app.javaClass.name}")
        return true
      } catch (t: Throwable) {
        android.util.Log.w(TAG, "setSpoofFongmiPackage failed", t)
        return false
      }
    }

    @JvmStatic
    fun startMergeLyGuard(durationMs: Long) {
      val h = Handler(Looper.getMainLooper())
      val start = SystemClock.uptimeMillis()
      val tick = object : Runnable {
        override fun run() {
          val removed = purgeMergeLyFromMainQueue()
          if (removed > 0) {
            android.util.Log.i(TAG, "mergeLyGuard purged=$removed")
          }
          if (SystemClock.uptimeMillis() - start < durationMs) {
            // 1ms：DexNative 偶发短延迟 post，16ms 会漏
            h.postDelayed(this, 1L)
          }
        }
      }
      // 立刻清一次，并插到队列前部压短竞态窗口
      h.postAtFrontOfQueue {
        purgeMergeLyFromMainQueue()
        h.post(tick)
      }
    }

    private fun spoofActivityThreadPackage(on: Boolean) {
      try {
        val atClass = Class.forName("android.app.ActivityThread")
        val at = atClass.getMethod("currentActivityThread").invoke(null) ?: return
        val boundField = atClass.getDeclaredField("mBoundApplication")
        boundField.isAccessible = true
        val bound = boundField.get(at) ?: return
        val appInfoField = bound.javaClass.getDeclaredField("appInfo")
        appInfoField.isAccessible = true
        val appInfo = appInfoField.get(bound) as ApplicationInfo
        if (on) {
          if (realActivityThreadPkg == null) {
            realActivityThreadPkg = appInfo.packageName
          }
          appInfo.packageName = FONGMI_PACKAGE
          appInfo.processName = FONGMI_PACKAGE
        } else {
          val real = realActivityThreadPkg
          if (real != null) {
            appInfo.packageName = real
            appInfo.processName = real
          }
        }
      } catch (t: Throwable) {
        android.util.Log.w(TAG, "spoofActivityThreadPackage failed", t)
      }
    }

    private fun purgeMergeLyFromMainQueue(): Int {
      var removed = 0
      try {
        val looper = Looper.getMainLooper() ?: return 0
        val queue = looper.queue
        val mMessages = android.os.MessageQueue::class.java.getDeclaredField("mMessages")
        mMessages.isAccessible = true
        val nextField = android.os.Message::class.java.getDeclaredField("next")
        nextField.isAccessible = true
        synchronized(queue) {
          var msg = mMessages.get(queue) as? android.os.Message
          var prev: android.os.Message? = null
          while (msg != null) {
            val next = nextField.get(msg) as? android.os.Message
            val cb = msg.callback
            if (cb != null && isJarHostConfigRunnable(cb)) {
              removed++
              msg.target?.removeCallbacks(cb)
              if (prev == null) {
                mMessages.set(queue, next)
              } else {
                nextField.set(prev, next)
              }
            } else {
              prev = msg
            }
            msg = next
          }
        }
      } catch (t: Throwable) {
        android.util.Log.w(TAG, "purgeMergeLyFromMainQueue failed", t)
      }
      return removed
    }

    private fun isJarHostConfigRunnable(runnable: Runnable): Boolean {
      val name = runnable.javaClass.name
      if (name.endsWith(".Ly") || name.contains("merge.Ly") || name.contains(".merge.L")) return true
      if ("Ly" == runnable.javaClass.simpleName) return true
      val trace = runnable.toString()
      return trace.contains("merge.Ly") || trace.contains("catvod.spider.merge.Ly")
    }

    @JvmStatic
    fun post(runnable: Runnable) {
      if (isJarHostConfigRunnable(runnable)) {
        android.util.Log.i(TAG, "skip jar host-config WebView runnable (宿主首页路径)")
        return
      }
      instance?.mainHandler?.post(runnable)
    }

    @JvmStatic
    fun post(runnable: Runnable, delayMillis: Long) {
      if (isJarHostConfigRunnable(runnable)) {
        android.util.Log.i(TAG, "skip jar host-config WebView runnable (delayed)")
        return
      }
      val h = instance?.mainHandler ?: return
      h.removeCallbacks(runnable)
      if (delayMillis >= 0) {
        h.postDelayed(runnable, delayMillis)
      }
    }

    @JvmStatic
    fun removeCallbacks(runnable: Runnable) {
      instance?.mainHandler?.removeCallbacks(runnable)
    }
  }
}
