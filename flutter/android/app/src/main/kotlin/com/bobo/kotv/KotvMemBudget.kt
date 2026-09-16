package com.bobo.kotv

import android.app.ActivityManager
import android.content.Context
import kotlin.math.max
import kotlin.math.min

/**
 * 与 Dart [KotvBufferBudget] 对齐的内存预算：约 15% avail 且 ≤ 总内存 5%；钳到 24–96MiB。
 * Exo / MPV 共用，避免两处拷贝漂移。
 */
object KotvMemBudget {
  fun bytes(ctx: Context?, desktop: Boolean = false): Int {
    val minB = if (desktop) 48L * 1024 * 1024 else 24L * 1024 * 1024
    val maxB = if (desktop) 384L * 1024 * 1024 else 96L * 1024 * 1024
    val fallback = if (desktop) 96 * 1024 * 1024 else 48 * 1024 * 1024
    if (ctx == null) return fallback
    return try {
      val am = ctx.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
      val mi = ActivityManager.MemoryInfo()
      am.getMemoryInfo(mi)
      var budget = (mi.totalMem * 0.05).toLong()
      if (mi.availMem > 0) {
        val byAvail = (mi.availMem * 0.15).toLong()
        if (byAvail in 1 until budget) budget = byAvail
      }
      max(minB, min(maxB, budget)).toInt()
    } catch (_: Throwable) {
      fallback
    }
  }
}
