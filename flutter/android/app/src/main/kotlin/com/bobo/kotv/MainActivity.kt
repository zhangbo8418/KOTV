package com.bobo.kotv

import android.Manifest
import android.app.Activity
import android.app.ActivityManager
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.content.res.Configuration
import android.media.AudioManager
import android.net.TrafficStats
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Rational
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

  private var spiderKickStarted = false
  private var androidChannel: MethodChannel? = null
  private var castPermResult: MethodChannel.Result? = null
  private var castMulticastLock: WifiManager.MulticastLock? = null
  private var pickConfigResult: MethodChannel.Result? = null
  private var storagePermResult: MethodChannel.Result? = null
  private var readMediaPermResult: MethodChannel.Result? = null
  private var externalPlayResult: MethodChannel.Result? = null
  /** 选择器里点过某个应用。关掉选择器时这个标记仍是假。 */
  private var externalChosen = false
  private val externalChosenReceiver = object : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
      externalChosen = true
    }
  }
  private var batteryPromptStarted = false
  /** 正在播放时：Home/切应用自动进系统画中画（Android 12+ setAutoEnterEnabled）。 */
  private var pipAutoEnter = false

  override fun onCreate(savedInstanceState: Bundle?) {
    // 冷启动即 edge-to-edge，状态栏/导航栏透明，壁纸可透到顶。
    WindowCompat.setDecorFitsSystemWindows(window, false)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
      window.statusBarColor = android.graphics.Color.TRANSPARENT
      window.navigationBarColor = android.graphics.Color.TRANSPARENT
    }
    // 刘海屏：默认模式横屏时不让画进刘海那条边，全屏播放那一侧被系统留黑，
    // 「适应屏幕」左右黑边不等宽。允许画进刘海区；非全屏页由 SafeArea 按刘海内边距避让。
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
      window.attributes = window.attributes.apply {
        layoutInDisplayCutoutMode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
          WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        } else {
          WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
      }
    }
    // 潇洒 jar：小米/夜间 getButtonTextColor=白，而 Theme.Light 的 multiChoice 列表偏浅 → 白字白底。
    // 只改 AlertDialog 主题，不整站改成常驻深色。
    if (jarNeedsDarkAlertDialogList()) {
      theme.applyStyle(R.style.KotvJarDarkAlertDialogOverlay, true)
    }
    super.onCreate(savedInstanceState)
    ContextCompat.registerReceiver(
      this,
      externalChosenReceiver,
      IntentFilter(EXTERNAL_CHOSEN),
      ContextCompat.RECEIVER_NOT_EXPORTED,
    )
  }

  override fun onDestroy() {
    try {
      unregisterReceiver(externalChosenReceiver)
    } catch (_: Throwable) {
    }
    super.onDestroy()
  }

  private fun jarNeedsDarkAlertDialogList(): Boolean {
    val m = Build.MANUFACTURER.orEmpty()
    if (m.equals("Xiaomi", true) || m.equals("Redmi", true)) return true
    val night = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK
    return night == Configuration.UI_MODE_NIGHT_YES
  }

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    flutterEngine.plugins.add(KotvExoPlugin())
    flutterEngine.plugins.add(KotvMpvPlugin())
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "kotv_android_spider")
      .setMethodCallHandler { call, result ->
        when (call.method) {
          "start" -> {
            try {
              SpiderServiceManager.start(this)
              result.success(true)
            } catch (t: Throwable) {
              result.error("spider_start", t.message ?: t.toString(), null)
            }
          }
          "stop" -> {
            SpiderServiceManager.stop()
            result.success(true)
          }
          "startEngine" -> {
            try {
              KotvEngineService.start(this)
              result.success(true)
            } catch (t: Throwable) {
              result.error("engine_start", t.message ?: t.toString(), null)
            }
          }
          "engineState" -> {
            result.success(mapOf("portTaken" to KotvEngineService.portTaken))
          }
          "stopEngine" -> {
            try {
              KotvEngineService.stop(this)
              result.success(true)
            } catch (t: Throwable) {
              result.error("engine_stop", t.message ?: t.toString(), null)
            }
          }
          "paths" -> {
            val cache = cacheDir.absolutePath
            val files = filesDir.absolutePath
            val codeCache = codeCacheDir.absolutePath
            val nativeLib = applicationInfo.nativeLibraryDir
            result.success(
              mapOf(
                "cacheDir" to cache,
                "filesDir" to files,
                "codeCacheDir" to codeCache,
                "nativeLibraryDir" to nativeLib,
                "enginePath" to File(nativeLib, "libkotv_engine.so").absolutePath,
                "lanIp" to (KotvDeviceEnv.lanIpv4(this) ?: ""),
                "timeZoneId" to KotvDeviceEnv.timeZoneId(),
              ),
            )
          }
          else -> result.notImplemented()
        }
      }

    androidChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "kotv_android")
    androidChannel?.setMethodCallHandler { call, result ->
      when (call.method) {
        "enterPip" -> {
          result.success(enterPipMode())
        }
        "setPipAutoEnter" -> {
          val on = call.arguments == true
          setPipAutoEnter(on)
          result.success(true)
        }
        "isInPip" -> {
          result.success(
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) isInPictureInPictureMode else false,
          )
        }
        "clearExoCache" -> {
          try {
            KotvExoCache.clear(this)
            result.success(true)
          } catch (e: Exception) {
            result.error("exo_cache", e.message, null)
          }
        }
        // cacheDir=包体+run 可变态；全部时外置 /TV/s_c_*（Go 另扫 filesDir/KOTV）。
        "clearCaches" -> {
          try {
            val script = call.argument<Boolean>("script") ?: false
            val jar = call.argument<Boolean>("jar") ?: false
            val other = call.argument<Boolean>("other") ?: false
            val all = call.argument<Boolean>("all") ?: false
            KotvCacheClean.clear(this, script, jar, other, all)
            result.success(true)
          } catch (e: Exception) {
            result.error("cache", e.message, null)
          }
        }
        "ensureCastPermissions" -> ensureCastPermissions(result)
        "ensureStoragePermission" -> ensureStoragePermission(result)
        "ensureReadMediaPermission" -> ensureReadMediaPermission(result)
        "pickConfigFile" -> pickConfigFile(result)
        "isTelevision" -> result.success(KotvFileChooser.isTelevision(this))
        "useFileBrowser" -> result.success(KotvFileChooser.shouldUseFileBrowser(this))
        "storageRoot" -> result.success(KotvFileChooser.storageRoot())
        "listDir" -> {
          val path = (call.arguments as? String)?.trim().orEmpty()
          result.success(KotvFileChooser.listDir(path))
        }
        "hasStoragePermission" -> result.success(KotvFileChooser.hasStoragePermission(this))
        "consumeJarDetailDismissed" -> result.success(KotvJarVideoActivity.consumeDismissed())
        "getMemoryInfo" -> {
          try {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val mi = ActivityManager.MemoryInfo()
            am.getMemoryInfo(mi)
            result.success(
              mapOf(
                "totalBytes" to mi.totalMem,
                "availBytes" to mi.availMem,
                "lowMemory" to mi.lowMemory,
                "threshold" to mi.threshold,
              ),
            )
          } catch (t: Throwable) {
            result.error("mem", t.message ?: t.toString(), null)
          }
        }
        // UID 下行流量（含同 UID 引擎子进程），缓冲浮层测速用。
        "getUidRxBytes" -> {
          try {
            val uid = applicationInfo.uid
            val rx = TrafficStats.getUidRxBytes(uid)
            result.success(if (rx == TrafficStats.UNSUPPORTED.toLong()) -1L else rx)
          } catch (t: Throwable) {
            result.error("traffic", t.message ?: t.toString(), null)
          }
        }
        "hasExternalVideoApp" -> result.success(externalVideoTargets().any { it.activityInfo?.packageName != packageName })
        "openExternalPlayer" -> openExternalPlayer(call, result)
        "openView" -> result.success(openView(call.argument<String>("url")))
        "isVulkanAvailable" -> {
          // FEATURE_VULKAN_HARDWARE_VERSION ≥ 1.2
          result.success(
            packageManager.hasSystemFeature(
              PackageManager.FEATURE_VULKAN_HARDWARE_VERSION,
              0x00402000,
            ),
          )
        }
        "getBrightness" -> result.success(windowBrightnessPercent())
        "setBrightness" -> {
          val p = (call.arguments as? Number)?.toFloat() ?: 50f
          setWindowBrightnessPercent(p)
          result.success(true)
        }
        "getSystemVolume" -> result.success(systemVolumePercent())
        "setSystemVolume" -> {
          val p = (call.arguments as? Number)?.toFloat() ?: 50f
          setSystemVolumePercent(p)
          result.success(true)
        }
        else -> result.notImplemented()
      }
    }
  }

  private fun windowBrightnessPercent(): Double {
    val lp = window.attributes
    val raw = lp.screenBrightness
    val v = if (raw < 0f) {
      try {
        Settings.System.getInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS) / 255f
      } catch (_: Exception) {
        0.5f
      }
    } else {
      raw
    }
    return (v.coerceIn(0f, 1f) * 100.0)
  }

  private fun setWindowBrightnessPercent(percent: Float) {
    val lp = window.attributes
    lp.screenBrightness = (percent / 100f).coerceIn(0.01f, 1f)
    window.attributes = lp
  }

  private fun systemVolumePercent(): Double {
    val am = getSystemService(AUDIO_SERVICE) as AudioManager
    val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
    val cur = am.getStreamVolume(AudioManager.STREAM_MUSIC)
    return cur.toDouble() / max * 100.0
  }

  private fun setSystemVolumePercent(percent: Float) {
    val am = getSystemService(AUDIO_SERVICE) as AudioManager
    val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
    val idx = ((percent / 100f) * max).toInt().coerceIn(0, max)
    am.setStreamVolume(AudioManager.STREAM_MUSIC, idx, 0)
  }

  /** ACTION_OPEN_DOCUMENT → 真实路径 file:// */
  private fun pickConfigFile(result: MethodChannel.Result) {
    if (pickConfigResult != null) {
      result.error("busy", "picker already open", null)
      return
    }
    pickConfigResult = result
    try {
      // FlutterActivity 不继承 ComponentActivity，不能用 registerForActivityResult
      @Suppress("DEPRECATION")
      startActivityForResult(KotvFileChooser.openDocumentIntent(), REQ_PICK_CONFIG)
    } catch (t: Throwable) {
      pickConfigResult = null
      result.error("pick", t.message ?: t.toString(), null)
    }
  }

  private fun ensureStoragePermission(result: MethodChannel.Result) {
    if (KotvFileChooser.canWriteSharedStorage(this)) {
      result.success(true)
      return
    }
    // API 30+ 写 /TVBox/ 必须进系统「所有文件访问」。resolveActivity 在部分机型为 null，仍要 start。
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
      storagePermResult = result
      val pkg = storagePackageName()
      val intents = listOf(
        Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
          data = Uri.parse("package:$pkg")
        },
        Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION),
      )
      for (intent in intents) {
        try {
          @Suppress("DEPRECATION")
          startActivityForResult(intent, REQ_MANAGE_STORAGE)
          return
        } catch (_: Throwable) {
        }
      }
      storagePermResult = null
      result.success(false)
      return
    }
    val need = storagePermissionsToRequest()
    if (need.isEmpty()) {
      result.success(KotvFileChooser.canWriteSharedStorage(this))
      return
    }
    castPermResult = null
    readMediaPermResult = null
    storagePermResult = result
    ActivityCompat.requestPermissions(this, need.toTypedArray(), REQ_STORAGE)
  }

  /** 选字体/字幕等只需读媒体，不强制「所有文件访问」。 */
  private fun ensureReadMediaPermission(result: MethodChannel.Result) {
    if (KotvFileChooser.canReadMedia(this)) {
      result.success(true)
      return
    }
    val need = readMediaPermissionsToRequest()
    if (need.isEmpty()) {
      result.success(KotvFileChooser.canReadMedia(this))
      return
    }
    castPermResult = null
    storagePermResult = null
    readMediaPermResult = result
    ActivityCompat.requestPermissions(this, need.toTypedArray(), REQ_READ_MEDIA)
  }

  private fun storagePackageName(): String {
    val real = try {
      com.fongmi.android.tv.App.realAppPackageName()
    } catch (_: Throwable) {
      ""
    }
    if (real.isNotEmpty()) return real
    return applicationInfo.packageName.takeIf { it.isNotEmpty() } ?: packageName
  }

  /** API < 30：系统运行时对话框申请 WRITE。 */
  private fun storagePermissionsToRequest(): List<String> {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) return emptyList()
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return emptyList()
    val perm = Manifest.permission.WRITE_EXTERNAL_STORAGE
    if (ContextCompat.checkSelfPermission(this, perm) == PackageManager.PERMISSION_GRANTED) {
      return emptyList()
    }
    return listOf(perm)
  }

  private fun readMediaPermissionsToRequest(): List<String> {
    val out = ArrayList<String>(2)
    when {
      Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> {
        out.add(Manifest.permission.READ_MEDIA_VIDEO)
        out.add(Manifest.permission.READ_MEDIA_AUDIO)
      }
      Build.VERSION.SDK_INT >= Build.VERSION_CODES.M -> {
        out.add(Manifest.permission.READ_EXTERNAL_STORAGE)
      }
    }
    return out.filter {
      ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
    }
  }

  // 不在 onPostResume 自动弹「所有文件访问」：仅选本地配置等文件入口显式 ensureStoragePermission。
  // 否则包名伪装期间误跳系统设置页，表现为点源配置后像回桌面。

  @Deprecated("Deprecated in Java")
  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
    @Suppress("DEPRECATION")
    super.onActivityResult(requestCode, resultCode, data)
    when (requestCode) {
      REQ_PICK_CONFIG -> {
        val pending = pickConfigResult
        pickConfigResult = null
        if (pending == null) return
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
          pending.success(null)
          return
        }
        val uri = data.data!!
        try {
          contentResolver.takePersistableUriPermission(
            uri,
            Intent.FLAG_GRANT_READ_URI_PERMISSION,
          )
        } catch (_: Throwable) {
        }
        val path = KotvFileChooser.getPathFromUri(this, uri)
        if (path.isNullOrBlank()) {
          pending.success(null)
          return
        }
        // 真实磁盘路径 → file://（绝对路径，相对 jar/js/py 相对该文件目录解析）
        pending.success(Uri.fromFile(File(path)).toString())
      }
      REQ_EXTERNAL_PLAYER -> {
        val pending = externalPlayResult
        externalPlayResult = null
        val opened = resultCode == Activity.RESULT_OK || externalChosen
        externalChosen = false
        if (pending == null) return
        if (!opened) {
          pending.success(mapOf("opened" to false))
          return
        }
        val extras = data?.extras
        pending.success(
          mapOf(
            "opened" to true,
            "endBy" to (extras?.getString("end_by") ?: ""),
            "positionMs" to (extras?.getInt("position", 0) ?: 0),
          ),
        )
      }
      REQ_MANAGE_STORAGE -> {
        storagePermResult?.success(KotvFileChooser.canWriteSharedStorage(this))
        storagePermResult = null
      }
    }
  }

  private fun pipParams(autoEnter: Boolean): PictureInPictureParams {
    val b = PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9))
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      b.setAutoEnterEnabled(autoEnter)
      b.setSeamlessResizeEnabled(true)
    }
    return b.build()
  }

  private fun setPipAutoEnter(enabled: Boolean) {
    pipAutoEnter = enabled
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
    try {
      setPictureInPictureParams(pipParams(enabled))
    } catch (_: Throwable) {
    }
  }

  private fun enterPipMode(): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
    if (isInPictureInPictureMode) return true
    return try {
      enterPictureInPictureMode(pipParams(pipAutoEnter))
    } catch (_: Throwable) {
      false
    }
  }

  override fun onUserLeaveHint() {
    super.onUserLeaveHint()
    if (!pipAutoEnter) return
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) return
    enterPipMode()
  }

  override fun onPictureInPictureModeChanged(
    isInPictureInPictureMode: Boolean,
    newConfig: Configuration,
  ) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
    }
    androidChannel?.invokeMethod("onPipChanged", isInPictureInPictureMode)
  }

  @Deprecated("Deprecated in Java")
  override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean) {
    super.onPictureInPictureModeChanged(isInPictureInPictureMode)
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
      androidChannel?.invokeMethod("onPipChanged", isInPictureInPictureMode)
    }
  }

  private fun ensureCastPermissions(result: MethodChannel.Result) {
    try {
      KotvEngineService.start(this)
    } catch (_: Throwable) {
    }
    try {
      if (castMulticastLock?.isHeld != true) {
        val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        castMulticastLock = wm.createMulticastLock("kotv:cast").apply {
          setReferenceCounted(false)
          acquire()
        }
      }
    } catch (_: Throwable) {
    }
    val need = mutableListOf<String>()
    if (Build.VERSION.SDK_INT >= 33) {
      if (ContextCompat.checkSelfPermission(this, Manifest.permission.NEARBY_WIFI_DEVICES)
        != PackageManager.PERMISSION_GRANTED
      ) {
        need.add(Manifest.permission.NEARBY_WIFI_DEVICES)
      }
    } else if (Build.VERSION.SDK_INT >= 23) {
      if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION)
        != PackageManager.PERMISSION_GRANTED
      ) {
        need.add(Manifest.permission.ACCESS_FINE_LOCATION)
      }
    }
    if (need.isEmpty()) {
      result.success(true)
      return
    }
    castPermResult = result
    ActivityCompat.requestPermissions(this, need.toTypedArray(), REQ_CAST)
  }

  override fun onRequestPermissionsResult(
    requestCode: Int,
    permissions: Array<out String>,
    grantResults: IntArray,
  ) {
    super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    if (requestCode == REQ_CAST) {
      val ok = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
      castPermResult?.success(ok)
      castPermResult = null
      return
    }
    if (requestCode == REQ_STORAGE) {
      storagePermResult?.success(KotvFileChooser.canWriteSharedStorage(this))
      storagePermResult = null
      return
    }
    if (requestCode == REQ_READ_MEDIA) {
      readMediaPermResult?.success(KotvFileChooser.canReadMedia(this))
      readMediaPermResult = null
    }
  }

  override fun onPostResume() {
    super.onPostResume()
    if (spiderKickStarted) return
    spiderKickStarted = true
    window.decorView.post {
      try {
        SpiderServiceManager.start(this)
      } catch (_: Throwable) {
      }
      try {
        KotvEngineService.start(this)
      } catch (_: Throwable) {
      }
      window.decorView.postDelayed({ promptIgnoreBatteryIfNeeded() }, 1200)
    }
  }

  /**
   * 锁屏作远端主机时，小米/HyperOS 等会在省电策略下冻死前台服务。
   * 只问一次，避免每次启动弹窗。
   */
  private fun promptIgnoreBatteryIfNeeded() {
    if (batteryPromptStarted || Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
    val prefs = getSharedPreferences("kotv", MODE_PRIVATE)
    if (prefs.getBoolean("asked_ignore_battery", false)) return
    val pm = getSystemService(android.os.PowerManager::class.java) ?: return
    if (pm.isIgnoringBatteryOptimizations(packageName)) {
      prefs.edit().putBoolean("asked_ignore_battery", true).apply()
      return
    }
    batteryPromptStarted = true
    prefs.edit().putBoolean("asked_ignore_battery", true).apply()
    try {
      startActivity(
        Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
          data = Uri.parse("package:$packageName")
        },
      )
    } catch (_: Throwable) {
    }
  }

  companion object {
    private const val REQ_CAST = 0xC457
    private const val REQ_STORAGE = 0xC458
    private const val REQ_PICK_CONFIG = 0xC459
    private const val REQ_MANAGE_STORAGE = 0xC45A
    private const val REQ_READ_MEDIA = 0xC45B
    private const val REQ_EXTERNAL_PLAYER = 0xC45C
    private const val EXTERNAL_CHOSEN = "com.bobo.kotv.EXTERNAL_PLAYER_CHOSEN"
  }

  private fun externalViewIntent(url: String): Intent {
    return Intent(Intent.ACTION_VIEW).apply {
      // 不带 NEW_TASK：否则 startActivityForResult 会立刻收到取消，进度交不回来。
      addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
      setDataAndType(Uri.parse(url), "video/*")
    }
  }

  @Suppress("DEPRECATION")
  private fun externalVideoTargets(): List<ResolveInfo> {
    return packageManager.queryIntentActivities(
      externalViewIntent("http://127.0.0.1/"),
      PackageManager.MATCH_DEFAULT_ONLY,
    )
  }

  private fun openView(raw: String?): Boolean {
    val target = raw?.trim().orEmpty()
    if (target.isEmpty()) return false
    return try {
      val intent = when {
        target.startsWith("package:") -> {
          val pkg = target.removePrefix("package:").substringBefore('/').substringBefore('?')
          packageManager.getLaunchIntentForPackage(pkg) ?: return false
        }
        target.startsWith("intent:") || target.contains("#Intent") ->
          Intent.parseUri(target, Intent.URI_INTENT_SCHEME)
        else -> {
          val parsed = Uri.parse(target)
          if (parsed.scheme.isNullOrEmpty() && target.contains('.')) {
            packageManager.getLaunchIntentForPackage(target) ?: return false
          } else {
            Intent(Intent.ACTION_VIEW, parsed)
          }
        }
      }
      startActivity(intent)
      true
    } catch (_: Throwable) {
      false
    }
  }

  private fun openExternalPlayer(call: MethodCall, result: MethodChannel.Result) {
    if (externalPlayResult != null) {
      result.error("busy", "外部播放器已打开", null)
      return
    }
    val url = call.argument<String>("url")?.trim().orEmpty()
    if (url.isEmpty()) {
      result.error("url", "empty url", null)
      return
    }
    val intent = externalViewIntent(url)
    val headerList = ArrayList<String>()
    val rawHeaders = call.argument<Map<*, *>>("headers")
    rawHeaders?.forEach { (k, v) ->
      val key = k?.toString()?.trim().orEmpty()
      val value = v?.toString()?.trim().orEmpty()
      if (key.isNotEmpty() && value.isNotEmpty()) {
        headerList.add(key)
        headerList.add(value)
      }
    }
    if (headerList.isNotEmpty()) {
      intent.putExtra("headers", headerList.toTypedArray())
    }
    val title = call.argument<String>("title")?.trim().orEmpty()
    if (title.isNotEmpty()) {
      intent.putExtra("title", title)
      intent.putExtra("name", title)
    }
    if (call.argument<Boolean>("vod") == true) {
      intent.putExtra("return_result", true)
      val pos = (call.argument<Number>("positionMs")?.toInt() ?: 0).coerceAtLeast(0)
      intent.putExtra("position", pos)
    }
    val self = externalVideoTargets().mapNotNull { info ->
      val act = info.activityInfo ?: return@mapNotNull null
      if (act.packageName != packageName) return@mapNotNull null
      ComponentName(act.packageName, act.name)
    }
    externalChosen = false
    val callback = Intent(EXTERNAL_CHOSEN).setPackage(packageName)
    val piFlags = PendingIntent.FLAG_UPDATE_CURRENT or
      (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
    val sender = PendingIntent.getBroadcast(this, REQ_EXTERNAL_PLAYER, callback, piFlags)
    val chooser = Intent.createChooser(intent, null, sender.intentSender)
      .putExtra(Intent.EXTRA_EXCLUDE_COMPONENTS, self.toTypedArray())
    externalPlayResult = result
    try {
      @Suppress("DEPRECATION")
      startActivityForResult(chooser, REQ_EXTERNAL_PLAYER)
    } catch (t: Throwable) {
      externalPlayResult = null
      result.error("external", t.message ?: t.toString(), null)
    }
  }
}
