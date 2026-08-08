package com.bobo.kotv

import android.Manifest
import android.app.ActivityManager
import android.app.PictureInPictureParams
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.TrafficStats
import android.os.Build
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
        "isInPip" -> {
          result.success(
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) isInPictureInPictureMode else false,
          )
        }
        "ensureCastPermissions" -> ensureCastPermissions(result)
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
        // 对齐 TV Traffic：缓冲浮层用 UID 下行字节差分测速（含引擎代理拉流）。
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

  private fun enterPipMode(): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
    return try {
      val params = PictureInPictureParams.Builder()
        .setAspectRatio(Rational(16, 9))
        .build()
      enterPictureInPictureMode(params)
    } catch (t: Throwable) {
      false
    }
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
    if (requestCode != REQ_CAST) return
    val ok = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
    castPermResult?.success(ok)
    castPermResult = null
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
    }
  }

  companion object {
    private const val REQ_CAST = 0xC457
  }
}
