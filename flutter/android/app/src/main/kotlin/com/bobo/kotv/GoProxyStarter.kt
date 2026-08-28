package com.bobo.kotv

import android.content.Context
import android.util.Log
import com.github.catvod.utils.Path
import java.io.File
import kotlin.concurrent.thread

/**
 * 对齐 TV 升级 SDK 前 [com.fongmi.android.tv.server.Go]：
 * jar ProxyVideo.go() 会 GET :9978/go，此处 chmod + exec go_proxy_video（监听 :7777）。
 *
 * 二进制来源：assets（若打包）、files/go_proxy_video、Path.so() 下载落盘。
 */
object GoProxyStarter {
  private const val TAG = "KotvGoProxy"
  private const val GO_NAME = "go_proxy_video"

  @Volatile
  private var prepared = false

  /** 首次把 assets 里的 go_proxy_video 拷到 files（对齐 TV prepare）。 */
  fun prepare(context: Context) {
    if (prepared) return
    synchronized(this) {
      if (prepared) return
      try {
        val dest = File(context.filesDir, GO_NAME)
        if (!dest.exists() || dest.length() == 0L) {
          context.assets.open(GO_NAME).use { input ->
            dest.outputStream().use { output -> input.copyTo(output) }
          }
          Log.i(TAG, "prepared asset -> ${dest.absolutePath}")
        }
        chmod(dest)
      } catch (_: Throwable) {
        // 潇洒哥等仓会自行下载到 Path.so()，无内置 assets 时正常。
      }
      prepared = true
    }
  }

  fun start(context: Context) {
    prepare(context)
    thread(name = "kotv-go-proxy-start", isDaemon = true) {
      try {
        val bin = resolveBinary(context) ?: run {
          Log.e(TAG, "go sidecar binary not found (download via spider or bundle assets/$GO_NAME)")
          return@thread
        }
        chmod(bin)
        killExisting()
        val pb =
          ProcessBuilder(bin.absolutePath)
            .directory(bin.parentFile ?: context.filesDir)
            .redirectErrorStream(true)
        pb.start()
        Log.i(TAG, "started go sidecar path=${bin.absolutePath}")
      } catch (t: Throwable) {
        Log.e(TAG, "start failed", t)
      }
    }
  }

  private fun resolveBinary(context: Context): File? {
    val fixed =
      listOf(
        File(context.filesDir, GO_NAME),
        File(context.cacheDir, GO_NAME),
      )
    for (f in fixed) {
      if (Path.exists(f)) return f
    }
    val soDir = Path.so()
    val fromSo = largestIn(soDir)
    if (fromSo != null) return fromSo
    return largestIn(context.filesDir)
  }

  private fun largestIn(dir: File): File? {
    val files = dir.listFiles()?.filter { it.isFile && it.length() > 64 * 1024 } ?: return null
    return files.maxByOrNull { it.length() }
  }

  private fun chmod(file: File) {
    try {
      file.setReadable(true, false)
      file.setWritable(true, false)
      file.setExecutable(true, false)
      Runtime.getRuntime()
        .exec(arrayOf("chmod", "777", file.absolutePath))
        .waitFor()
    } catch (t: Throwable) {
      Log.w(TAG, "chmod ${file.name}", t)
    }
  }

  private fun killExisting() {
    for (cmd in arrayOf(arrayOf("pkill", "-f", GO_NAME), arrayOf("killall", "-9", GO_NAME))) {
      try {
        Runtime.getRuntime().exec(cmd).waitFor()
      } catch (_: Throwable) {
      }
    }
  }
}
