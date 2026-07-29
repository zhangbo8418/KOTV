package com.bobo.kotv

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "kotv_android_spider")
      .setMethodCallHandler { call, result ->
        when (call.method) {
          "start" -> {
            SpiderServiceManager.start(this)
            result.success(true)
          }
          "stop" -> {
            SpiderServiceManager.stop()
            result.success(true)
          }
          else -> result.notImplemented()
        }
      }
  }
}
