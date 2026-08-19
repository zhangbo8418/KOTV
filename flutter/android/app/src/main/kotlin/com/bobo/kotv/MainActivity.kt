package com.bobo.kotv

import android.Manifest
import android.app.Activity
import android.app.ActivityManager
import android.app.PictureInPictureParams
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.TrafficStats
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Rational
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

  private var spiderKickStarted = false
  private var androidChannel: MethodChannel? = null
  private var castPermResult: MethodChannel.Result? = null
  private var pickConfigResult: MethodChannel.Result? = null
  private var storagePermResult: MethodChannel.Result? = null
  private var storagePromptStarted = false
  private var batteryPromptStarted = false
  /** 正在播放时：Home/切应用自动进系统画中画（Android 12+ setAutoEnterEnabled）。 */
  private var pipAutoEnter = false

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    flutterEngine.plugins.add(KotvExoPlugin())
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
              ),
            )
          }
          "interruptJar" -> {
            try {
              JarLoader.clear()
            } catch (_: Throwable) {
            }
            result.success(true)
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
        "ensureCastPermissions" -> ensureCastPermissions(result)
        "ensureStoragePermission" -> ensureStoragePermission(result)
        "pickConfigFile" -> pickConfigFile(result)
        "useFileBrowser" -> result.success(KotvFileChooser.shouldUseFileBrowser(this))
        "storageRoot" -> result.success(KotvFileChooser.storageRoot())
        "listDir" -> {
          val path = (call.arguments as? String)?.trim().orEmpty()
          result.success(KotvFileChooser.listDir(path))
        }
        "hasStoragePermission" -> result.success(KotvFileChooser.hasStoragePermission(this))
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
        // 对齐 TV Traffic：UID 下行（含同 UID 引擎子进程），缓冲浮层测速用。
        "getUidRxBytes" -> {
          try {
            val uid = applicationInfo.uid
            val rx = TrafficStats.getUidRxBytes(uid)
            result.success(if (rx == TrafficStats.UNSUPPORTED.toLong()) -1L else rx)
          } catch (t: Throwable) {
            result.error("traffic", t.message ?: t.toString(), null)
          }
        }
        else -> result.notImplemented()
      }
    }
  }

  /** 对齐 TV ConfigDialog：ACTION_OPEN_DOCUMENT → 真实路径 file:// */
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
    if (KotvFileChooser.hasStoragePermission(this)) {
      result.success(true)
      return
    }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && canRequestAllFilesAccess()) {
      storagePermResult = result
      try {
        val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
        intent.data = Uri.parse("package:$packageName")
        @Suppress("DEPRECATION")
        startActivityForResult(intent, REQ_MANAGE_STORAGE)
      } catch (_: Throwable) {
        try {
          @Suppress("DEPRECATION")
          startActivityForResult(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION), REQ_MANAGE_STORAGE)
        } catch (t: Throwable) {
          storagePermResult = null
          result.error("storage", t.message ?: t.toString(), null)
        }
      }
      return
    }
    val need = storagePermissionsToRequest()
    if (need.isEmpty()) {
      result.success(true)
      return
    }
    castPermResult = null
    storagePermResult = result
    ActivityCompat.requestPermissions(this, need.toTypedArray(), REQ_STORAGE)
  }

  /** 对齐 TV PermissionUtil：部分 TV/盒子没有「所有文件访问」设置页，改走运行时读权限。 */
  private fun canRequestAllFilesAccess(): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
    val app = Intent(
      Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
      Uri.parse("package:$packageName"),
    )
    val all = Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
    return app.resolveActivity(packageManager) != null ||
      all.resolveActivity(packageManager) != null
  }

  private fun storagePermissionsToRequest(): List<String> {
    val out = ArrayList<String>(3)
    when {
      Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> {
        out.add(Manifest.permission.READ_MEDIA_VIDEO)
        out.add(Manifest.permission.READ_MEDIA_AUDIO)
      }
      Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> {
        out.add(Manifest.permission.READ_EXTERNAL_STORAGE)
      }
      else -> {
        out.add(Manifest.permission.READ_EXTERNAL_STORAGE)
        out.add(Manifest.permission.WRITE_EXTERNAL_STORAGE)
      }
    }
    return out.filter {
      ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
    }
  }

  /** 首启对齐 TV HomeActivity：尽早申请本地文件访问。 */
  private fun promptStoragePermissionIfNeeded() {
    if (storagePromptStarted || KotvFileChooser.hasStoragePermission(this)) return
    storagePromptStarted = true
    ensureStoragePermission(
      object : MethodChannel.Result {
        override fun success(result: Any?) {}

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}

        override fun notImplemented() {}
      },
    )
  }

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
        // 对齐 TV：真实磁盘路径 → file://（绝对路径，相对 jar/js/py 相对该文件目录解析）
        pending.success(Uri.fromFile(File(path)).toString())
      }
      REQ_MANAGE_STORAGE -> {
        storagePermResult?.success(KotvFileChooser.hasStoragePermission(this))
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
      val ok = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
      storagePermResult?.success(ok)
      storagePermResult = null
    }
  }

  override fun onPostResume() {
    super.onPostResume()
    if (spiderKickStarted) return
    spiderKickStarted = true
    window.decorView.post {
      promptStoragePermissionIfNeeded()
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
  }
}
