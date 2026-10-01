package com.bobo.kotv

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.util.Log
import java.lang.ref.WeakReference
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * 短生命周期透明页：承接 jar 里对 [Activity.finish] 的调用。
 *
 * 类名含 Video：摸鱼儿 FishConfig.g0 会 finish 含 Detail/Video 的 Activity，
 * 再异步弹 AlertDialog；关本页后弹窗可挂回 MainActivity。
 *
 * VOX Config.doDetailContent 也会 finish 顶层页；有本页则不会关掉 MainActivity。
 * 勿用于 spider.action：异步 AlertDialog 会挂在本页上，leave 时随 finish 消失。
 */
class KotvJarVideoActivity : Activity() {

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    current = WeakReference(this)
  }

  override fun onResume() {
    super.onResume()
    current = WeakReference(this)
    signalReady()
  }

  override fun onDestroy() {
    val cur = current?.get()
    if (cur === this) current = null
    signalReady()
    super.onDestroy()
  }

  companion object {
    private const val TAG = "KotvJarVideo"
    private val depth = AtomicInteger(0)
    @Volatile private var current: WeakReference<KotvJarVideoActivity>? = null
    @Volatile private var readyLatch: CountDownLatch? = null

    /** @return 是否由本次调用负责 [leave]（嵌套 enter 返回 false）。 */
    @JvmStatic
    fun enter(context: Context?): Boolean {
      if (context == null) return false
      val prev = depth.getAndIncrement()
      if (prev > 0) return false
      val existing = current?.get()
      if (existing != null && !existing.isFinishing && !isDestroyedSafe(existing)) {
        return true
      }
      val latch = CountDownLatch(1)
      readyLatch = latch
      try {
        val intent = Intent(context, KotvJarVideoActivity::class.java)
        intent.addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION)
        when (context) {
          is Activity -> {
            if (!context.isFinishing && !isDestroyedSafe(context)) {
              context.startActivity(intent)
            } else {
              intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
              context.applicationContext.startActivity(intent)
            }
          }
          else -> {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.applicationContext.startActivity(intent)
          }
        }
        val ok = latch.await(2500, TimeUnit.MILLISECONDS)
        if (!ok) Log.w(TAG, "session activity resume timeout")
        return true
      } catch (t: Throwable) {
        Log.w(TAG, "enter session failed", t)
        depth.set(0)
        readyLatch = null
        return false
      }
    }

    @JvmStatic
    fun leave() {
      val d = depth.decrementAndGet()
      if (d > 0) return
      if (d < 0) depth.set(0)
      val act = current?.get() ?: return
      try {
        if (!act.isFinishing && !isDestroyedSafe(act)) {
          act.runOnUiThread {
            try {
              act.finish()
            } catch (_: Throwable) {
            }
          }
        }
      } catch (_: Throwable) {
      }
    }

    private fun isDestroyedSafe(act: Activity): Boolean {
      return try {
        act.isDestroyed
      } catch (_: Throwable) {
        false
      }
    }

    private fun signalReady() {
      readyLatch?.countDown()
      readyLatch = null
    }
  }
}
