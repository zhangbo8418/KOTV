package com.bobo.kotv

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * 前台服务托管本机 Go 引擎（libkotv_engine.so）。
 *
 * 根因：Dart [Process.start] 拉起的子进程在 App 进后台后常被 OEM（红米/HyperOS）杀掉；
 * 详情页仍用内存缓存所以看起来正常，一点播放打 :9978 就 Connection closed，随后整站 API 全挂。
 * 用前景服务抬高进程优先级，并在服务内拉起/守护引擎。
 */
class KotvEngineService : Service() {

  private var engineProcess: Process? = null
  private val starting = AtomicBoolean(false)

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    when (intent?.action) {
      ACTION_STOP -> {
        stopEngine()
        stopForegroundCompat()
        stopSelf()
        return START_NOT_STICKY
      }
      else -> {
        startAsForeground()
        thread(name = "kotv-engine-ensure", isDaemon = true) {
          ensureEngine()
        }
        return START_STICKY
      }
    }
  }

  override fun onDestroy() {
    stopEngine()
    super.onDestroy()
  }

  private fun startAsForeground() {
    ensureChannel()
    val pi = PendingIntent.getActivity(
      this,
      0,
      Intent(this, MainActivity::class.java),
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
    val notif: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
      .setContentTitle("KO影视")
      .setContentText("后台引擎运行中")
      .setSmallIcon(R.mipmap.ic_launcher)
      .setContentIntent(pi)
      .setOngoing(true)
      .setSilent(true)
      .setPriority(NotificationCompat.PRIORITY_LOW)
      .build()
    if (Build.VERSION.SDK_INT >= 29) {
      startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
    } else {
      @Suppress("DEPRECATION")
      startForeground(NOTIF_ID, notif)
    }
  }

  private fun stopForegroundCompat() {
    if (Build.VERSION.SDK_INT >= 24) {
      stopForeground(STOP_FOREGROUND_REMOVE)
    } else {
      @Suppress("DEPRECATION")
      stopForeground(true)
    }
  }

  private fun ensureChannel() {
    if (Build.VERSION.SDK_INT < 26) return
    val nm = getSystemService(NotificationManager::class.java) ?: return
    val ch = NotificationChannel(CHANNEL_ID, "引擎保活", NotificationManager.IMPORTANCE_LOW).apply {
      description = "保持本机解析引擎在后台不被系统杀掉"
      setShowBadge(false)
    }
    nm.createNotificationChannel(ch)
  }

  private fun ensureEngine() {
    if (engineHealthy()) {
      Log.i(TAG, "engine already healthy on :9978")
      return
    }
    if (!starting.compareAndSet(false, true)) return
    try {
      stopEngine()
      val so = resolveEngineSo() ?: run {
        Log.e(TAG, "libkotv_engine.so not found")
        return
      }
      Log.i(TAG, "spawning engine: $so")
      val pb = ProcessBuilder(so)
        .directory(File(so).parentFile)
        .redirectErrorStream(true)
      val env = pb.environment()
      env["KOTV_CACHE_DIR"] = cacheDir.absolutePath
      env["KOTV_DATA_DIR"] = File(cacheDir, "KOTV").absolutePath
      env["HOME"] = filesDir.absolutePath
      // 与 Flutter 同 UID；降低被杀概率时仍可能写日志
      val proc = pb.start()
      engineProcess = proc
      thread(name = "kotv-engine-log", isDaemon = true) {
        try {
          BufferedReader(InputStreamReader(proc.inputStream)).use { br ->
            var line: String?
            while (br.readLine().also { line = it } != null) {
              Log.i(TAG, "[engine] $line")
            }
          }
        } catch (_: Throwable) {
        }
      }
      thread(name = "kotv-engine-watch", isDaemon = true) {
        val code = try {
          proc.waitFor()
        } catch (_: Throwable) {
          -1
        }
        Log.w(TAG, "engine exited code=$code")
        if (engineProcess === proc) {
          engineProcess = null
        }
        // 服务还在则自动拉起（后台被杀后的自愈）
        if (running.get()) {
          Thread.sleep(800)
          ensureEngine()
        }
      }
      // 等 HTTP 起来
      for (i in 0 until 40) {
        if (engineHealthy()) {
          Log.i(TAG, "engine ready after spawn")
          return
        }
        if (!proc.isAlive) {
          Log.e(TAG, "engine died during boot")
          return
        }
        Thread.sleep(250)
      }
      Log.w(TAG, "engine spawn timeout waiting :9978")
    } catch (t: Throwable) {
      Log.e(TAG, "ensureEngine failed", t)
    } finally {
      starting.set(false)
    }
  }

  private fun stopEngine() {
    val p = engineProcess
    engineProcess = null
    if (p == null) return
    try {
      p.destroy()
    } catch (_: Throwable) {
    }
    try {
      if (Build.VERSION.SDK_INT >= 26) {
        p.destroyForcibly()
      }
    } catch (_: Throwable) {
    }
  }

  private fun resolveEngineSo(): String? {
    val native = File(applicationInfo.nativeLibraryDir, "libkotv_engine.so")
    if (native.exists()) return native.absolutePath
    val cached = File(codeCacheDir, "libkotv_engine.so")
    if (cached.exists()) return cached.absolutePath
    return null
  }

  private fun engineHealthy(): Boolean {
    return try {
      val url = URL("http://127.0.0.1:9978/api/v1/health")
      val conn = (url.openConnection() as HttpURLConnection).apply {
        connectTimeout = 800
        readTimeout = 800
        requestMethod = "GET"
      }
      try {
        val code = conn.responseCode
        if (code !in 200..299) return false
        val body = conn.inputStream.bufferedReader().use { it.readText() }
        val ok = JSONObject(body).optBoolean("ok", false)
        ok
      } finally {
        conn.disconnect()
      }
    } catch (_: Throwable) {
      false
    }
  }

  companion object {
    private const val TAG = "KotvEngineService"
    private const val CHANNEL_ID = "kotv_engine"
    private const val NOTIF_ID = 0x4B0E
    const val ACTION_START = "com.bobo.kotv.action.START_ENGINE"
    const val ACTION_STOP = "com.bobo.kotv.action.STOP_ENGINE"

    private val running = AtomicBoolean(false)

    fun start(context: Context) {
      running.set(true)
      val i = Intent(context, KotvEngineService::class.java).setAction(ACTION_START)
      ContextCompat.startForegroundService(context, i)
    }

    fun stop(context: Context) {
      running.set(false)
      try {
        context.startService(Intent(context, KotvEngineService::class.java).setAction(ACTION_STOP))
      } catch (t: Throwable) {
        Log.w(TAG, "stop failed", t)
      }
    }

    fun isRunning(): Boolean = running.get()
  }
}
