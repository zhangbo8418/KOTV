package com.bobo.kotv

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
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
  private var cpuWakeLock: PowerManager.WakeLock? = null
  private var wifiLock: WifiManager.WifiLock? = null
  private var multicastLock: WifiManager.MulticastLock? = null

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    when (intent?.action) {
      ACTION_STOP -> {
        stopEngine()
        releaseStayLocks()
        stopForegroundCompat()
        stopSelf()
        return START_NOT_STICKY
      }
      else -> {
        startAsForeground()
        acquireStayLocks()
        thread(name = "kotv-engine-ensure", isDaemon = true) {
          // 作远端主机时 PC 打 :9978，Go 再打本机 :9979 —— 必须与引擎同保活。
          try {
            SpiderServiceManager.start(this@KotvEngineService)
          } catch (t: Throwable) {
            Log.e(TAG, "spider start failed", t)
          }
          ensureEngine()
        }
        return START_STICKY
      }
    }
  }

  override fun onDestroy() {
    stopEngine()
    releaseStayLocks()
    super.onDestroy()
  }

  /** CPU + Wi‑Fi 不随锁屏休眠，远端才能打到本机引擎。不持有亮屏锁。 */
  private fun acquireStayLocks() {
    try {
      val held = cpuWakeLock?.isHeld == true
      if (!held) {
        val pm = getSystemService(PowerManager::class.java)
        cpuWakeLock = pm?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "kotv:engine")?.apply {
          setReferenceCounted(false)
          acquire()
        }
      }
    } catch (t: Throwable) {
      Log.w(TAG, "cpu wake lock failed", t)
    }
    try {
      val held = wifiLock?.isHeld == true
      if (!held) {
        val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val mode = if (Build.VERSION.SDK_INT >= 29) {
          WifiManager.WIFI_MODE_FULL_LOW_LATENCY
        } else {
          @Suppress("DEPRECATION")
          WifiManager.WIFI_MODE_FULL_HIGH_PERF
        }
        wifiLock = try {
          wm.createWifiLock(mode, "kotv:engine-wifi")
        } catch (_: Throwable) {
          @Suppress("DEPRECATION")
          wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "kotv:engine-wifi")
        }?.apply {
          setReferenceCounted(false)
          acquire()
        }
      }
    } catch (t: Throwable) {
      Log.w(TAG, "wifi lock failed", t)
    }
    try {
      if (multicastLock?.isHeld != true) {
        val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wm.createMulticastLock("kotv:ssdp").apply {
          setReferenceCounted(false)
          acquire()
        }
      }
    } catch (t: Throwable) {
      Log.w(TAG, "multicast lock failed", t)
    }
  }

  private fun releaseStayLocks() {
    try {
      if (cpuWakeLock?.isHeld == true) cpuWakeLock?.release()
    } catch (_: Throwable) {
    }
    cpuWakeLock = null
    try {
      if (wifiLock?.isHeld == true) wifiLock?.release()
    } catch (_: Throwable) {
    }
    wifiLock = null
    try {
      if (multicastLock?.isHeld == true) multicastLock?.release()
    } catch (_: Throwable) {
    }
    multicastLock = null
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
      .setContentText("后台运行中")
      .setSmallIcon(R.mipmap.ic_launcher)
      .setContentIntent(pi)
      .setOngoing(true)
      .setSilent(true)
      .setPriority(NotificationCompat.PRIORITY_LOW)
      .build()
    if (Build.VERSION.SDK_INT >= 29) {
      startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
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
    relaxNicOffload()
    if (engineHealthy()) {
      Log.i(TAG, "engine already healthy on :9978")
      return
    }
    if (!starting.compareAndSet(false, true)) return
    try {
      stopEngine()
      killStrayEngines()
      portTaken = false
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
      // 持久数据进 filesDir，避免清缓存/系统清 cache 丢掉多仓 DB。
      env["KOTV_DATA_DIR"] = File(filesDir, "KOTV").absolutePath
      env["HOME"] = filesDir.absolutePath
      // 猫爪 Node：libkotv_node.so / libnode.so 与引擎同 nativeLibraryDir。
      env["KOTV_NATIVE_LIB_DIR"] = File(so).parentFile?.absolutePath ?: applicationInfo.nativeLibraryDir
      KotvDeviceEnv.lanIpv4(this)?.let { env["KOTV_LAN_IP"] = it }
      // 注入设备 IANA 时区，Go 用 tzdata LoadLocation。
      val tz = KotvDeviceEnv.timeZoneId()
      if (tz.isNotEmpty()) {
        env["KOTV_TZ"] = tz
        env["TZ"] = tz
      }
      try {
        env["KOTV_LOCALE_COUNTRY"] = java.util.Locale.getDefault().country ?: ""
      } catch (_: Throwable) {
      }
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
        // 端口被别的程序占着：重拉也绑不上，等前端重试时再拉。
        if (code == KotvEngineDefaults.EXIT_PORT_IN_USE) {
          portTaken = true
          Log.w(TAG, ":9978 taken by another app; not restarting")
          return@thread
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
        if (!processAlive(proc)) {
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
    // 等它真正退出、放开端口；否则新引擎会以「端口被占」退出。
    waitUntil { !processAlive(p) }
  }

  /** 最多等 1.5 秒直到 [done] 为真。 */
  private fun waitUntil(done: () -> Boolean) {
    repeat(15) {
      if (done()) return
      Thread.sleep(100)
    }
  }

  /**
   * 结束本应用残留的引擎进程（服务重启后丢了句柄的旧进程，可能卡住还占着端口），并等它们退出。
   * /proc 只看得到同 UID 的进程，killProcess 也只对同 UID 生效。
   */
  private fun killStrayEngines() {
    val self = android.os.Process.myPid()
    fun strays(): List<Int> = File("/proc").listFiles().orEmpty().mapNotNull { dir ->
      val pid = dir.name.toIntOrNull() ?: return@mapNotNull null
      if (pid == self) return@mapNotNull null
      val cmd = try {
        File(dir, "cmdline").readText()
      } catch (_: Throwable) {
        return@mapNotNull null
      }
      pid.takeIf { cmd.contains("libkotv_engine.so") && !cmd.contains("-relax-nic") }
    }
    val left = strays()
    if (left.isEmpty()) return
    Log.w(TAG, "killing stray engine pids=$left")
    left.forEach { android.os.Process.killProcess(it) }
    waitUntil { strays().isEmpty() }
  }

  /**
   * 关掉发送校验卸载和 GSO。RK3399 gmac 重传满尺寸 TCP 段时校验错误，
   * Win7 不确认，播放就停在这一条连接上。需要 root；没有 su 就跳过。
   */
  private fun relaxNicOffload() {
    if (!nicRelaxTried.compareAndSet(false, true)) return
    val so = resolveEngineSo() ?: return
    val proc = try {
      ProcessBuilder("su", "-c", "\"$so\" -relax-nic")
        .redirectErrorStream(true)
        .start()
    } catch (t: Throwable) {
      Log.w(TAG, "relax-nic su unavailable", t)
      return
    }
    val out = StringBuilder()
    val reader = thread(name = "kotv-relax-nic-read", isDaemon = true) {
      try {
        out.append(proc.inputStream.bufferedReader().readText())
      } catch (_: Throwable) {
      }
    }
    var code = -1
    val waiter = thread(name = "kotv-relax-nic-wait", isDaemon = true) {
      code = try {
        proc.waitFor()
      } catch (_: Throwable) {
        -1
      }
    }
    waiter.join(4000)
    if (waiter.isAlive) {
      try {
        proc.destroy()
      } catch (_: Throwable) {
      }
      Log.w(TAG, "relax-nic timed out")
      return
    }
    reader.join(1000)
    Log.i(TAG, "relax-nic code=$code ${out.toString().trim()}")
  }

  private fun resolveEngineSo(): String? {
    val native = File(applicationInfo.nativeLibraryDir, "libkotv_engine.so")
    if (native.exists()) return native.absolutePath
    val cached = File(codeCacheDir, "libkotv_engine.so")
    if (cached.exists()) return cached.absolutePath
    return null
  }

  /** API 25 无 [Process.isAlive]；用 exitValue 探测，避免守护线程 NoSuchMethodError。 */
  private fun processAlive(proc: Process): Boolean {
    return if (Build.VERSION.SDK_INT >= 26) {
      proc.isAlive
    } else {
      try {
        proc.exitValue()
        false
      } catch (_: IllegalThreadStateException) {
        true
      }
    }
  }

  /** :9978 上是本引擎在答（KOTV 健康检查 ok）。 */
  private fun engineHealthy(): Boolean {
    return try {
      val conn = (URL("${KotvEngineDefaults.BASE_URL}/api/v1/health").openConnection() as HttpURLConnection).apply {
        connectTimeout = 800
        readTimeout = 800
        requestMethod = "GET"
      }
      try {
        if (conn.responseCode !in 200..299) return false
        val json = JSONObject(conn.inputStream.bufferedReader().use { it.readText() })
        json.optString("engine") == "kotv" && json.optBoolean("ok", false)
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

    /** 网卡卸载设置一直生效到重启；每次 su 都会弹授权提示，进程内只试一次。 */
    private val nicRelaxTried = AtomicBoolean(false)

    /** 引擎因 :9978 被别的程序占着退出过；前端经 engineState 读取，下次拉起前清掉。 */
    @Volatile
    var portTaken = false
      private set

    fun start(context: Context) {
      running.set(true)
      // 前端重试时立刻清掉上一次的结果，免得在新引擎起来前读到旧的「被占」。
      portTaken = false
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
