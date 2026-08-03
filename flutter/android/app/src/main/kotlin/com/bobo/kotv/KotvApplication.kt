package com.bobo.kotv

import android.app.Application
import android.content.Context
import com.github.catvod.Init

/**
 * 对齐 TV [App.attachBaseContext]：最早注入 [Init]，供迅雷 AAR / Path 使用。
 * 勿在此预热 XLTaskHelper（TV 也是首次 parse/fetch 才 loadLibrary）。
 */
class KotvApplication : Application() {
  override fun attachBaseContext(base: Context) {
    super.attachBaseContext(base)
    try {
      Init.set(base)
    } catch (_: Throwable) {
    }
  }

  override fun onCreate() {
    super.onCreate()
    try {
      Init.set(this)
    } catch (_: Throwable) {
    }
  }
}
