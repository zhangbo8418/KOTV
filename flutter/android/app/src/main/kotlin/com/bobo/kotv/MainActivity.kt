package com.bobo.kotv

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

  private var spiderKickStarted = false

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

  override fun onPostResume() {
    super.onPostResume()
    // 等首帧/插件注册完成后再拉 :9979，避免与 texture/GPU 初始化抢资源
    if (spiderKickStarted) return
    spiderKickStarted = true
    window.decorView.post {
      try {
        SpiderServiceManager.start(this)
      } catch (_: Throwable) {
      }
    }
  }
}
