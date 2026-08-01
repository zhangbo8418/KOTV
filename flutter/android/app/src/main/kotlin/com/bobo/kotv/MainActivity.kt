package com.bobo.kotv

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    // 尽早拉起 :9979，避免仅依赖 Dart 侧调用时序
    try {
      SpiderServiceManager.start(this)
    } catch (_: Throwable) {
    }
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
          "paths" -> {
            val cache = cacheDir.absolutePath
            val files = filesDir.absolutePath
            // codeCacheDir 可执行；files/cache 在 Android 10+ 常为 noexec
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
  }
}
