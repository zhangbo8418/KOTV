package com.bobo.kotv.extractor

import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.net.Uri
import android.os.IBinder
import android.os.SystemClock
import android.util.Log
import com.forcetech.Util
import com.github.catvod.Init
import com.github.catvod.net.OkHttp
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.regex.Pattern

/**
 * p2p / p3p / mitv → 本机 ForceTech HTTP。
 */
object ForceExtractor : ServiceConnection {
  private const val TAG = "KotvForce"
  private val PATTERN = Pattern.compile("(?i)(p[2-9]p|mitv)")
  private val ready = ConcurrentHashMap.newKeySet<String>()

  fun match(url: String): Boolean {
    return try {
      val scheme = Uri.parse(url.trim()).scheme ?: return false
      PATTERN.matcher(scheme).find()
    } catch (_: Throwable) {
      false
    }
  }

  fun fetch(url: String): String {
    val ctx = Init.context() ?: throw IllegalStateException("no app context")
    val scheme = Util.scheme(url)
    if (!ready.contains(scheme)) {
      try {
        ctx.bindService(Util.intent(ctx, scheme), this, Context.BIND_AUTO_CREATE)
      } catch (t: Throwable) {
        Log.e(TAG, "bind $scheme failed", t)
        throw t
      }
      val deadline = SystemClock.elapsedRealtime() + 8_000L
      while (!ready.contains(scheme) && SystemClock.elapsedRealtime() < deadline) {
        SystemClock.sleep(20)
      }
      if (!ready.contains(scheme)) {
        throw IllegalStateException("ForceTech $scheme 未就绪")
      }
    }
    val uri = Uri.parse(url.trim())
    val port = Util.port(scheme)
    val id = uri.lastPathSegment ?: throw IllegalStateException("empty force id")
    val host = uri.host ?: throw IllegalStateException("empty force host")
    val portPart = if (uri.port > 0) ":${uri.port}" else ""
    val cmd =
      "http://127.0.0.1:$port/cmd.xml?cmd=switch_chan&server=$host$portPart&id=$id"
    OkHttp.string(cmd, mapOf("User-Agent" to "MTV"))
    return "http://127.0.0.1:$port/$id"
  }

  fun stop() {
    // 保持服务；换台可复用已 bind 的 scheme
  }

  fun exit() {
    val ctx = Init.context() ?: return
    try {
      if (ready.isNotEmpty()) ctx.unbindService(this)
    } catch (t: Throwable) {
      Log.w(TAG, "unbind", t)
    } finally {
      ready.clear()
    }
  }

  override fun onServiceConnected(name: ComponentName, service: IBinder?) {
    ready.add(Util.trans(name).lowercase(Locale.US))
  }

  override fun onServiceDisconnected(name: ComponentName) {
    ready.remove(Util.trans(name).lowercase(Locale.US))
  }
}
