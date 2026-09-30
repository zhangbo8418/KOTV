package com.bobo.kotv

import android.content.Context
import android.net.wifi.WifiManager
import android.util.Log
import java.util.TimeZone

/** 安卓侧设备环境：局域网 IP、系统时区（供引擎进程环境变量注入）。 */
object KotvDeviceEnv {
  private const val TAG = "KotvDeviceEnv"

  fun timeZoneId(): String =
    try {
      TimeZone.getDefault().id.orEmpty()
    } catch (_: Throwable) {
      ""
    }

  /** 含夏令时的当前偏移（毫秒，东为正）；IANA LoadLocation 失败时供 Go FixedZone。 */
  fun timeZoneOffsetMs(): Int =
    try {
      TimeZone.getDefault().getOffset(System.currentTimeMillis())
    } catch (_: Throwable) {
      0
    }

  fun lanIpv4(context: Context): String? {
    try {
      val wm = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
      @Suppress("DEPRECATION")
      val ipInt = wm.connectionInfo?.ipAddress ?: 0
      if (ipInt != 0) {
        return String.format(
          java.util.Locale.US,
          "%d.%d.%d.%d",
          ipInt and 0xff,
          ipInt shr 8 and 0xff,
          ipInt shr 16 and 0xff,
          ipInt shr 24 and 0xff,
        )
      }
    } catch (t: Throwable) {
      Log.w(TAG, "wifi ip failed", t)
    }
    // Java NetworkInterface 在 Android 11+ 仍可用；Go net.Interfaces 会 netlinkrib。
    try {
      val en = java.net.NetworkInterface.getNetworkInterfaces() ?: return null
      while (en.hasMoreElements()) {
        val iface = en.nextElement()
        if (!iface.isUp || iface.isLoopback) continue
        val addrs = iface.inetAddresses
        while (addrs.hasMoreElements()) {
          val a = addrs.nextElement()
          if (a is java.net.Inet4Address && !a.isLoopbackAddress) {
            return a.hostAddress
          }
        }
      }
    } catch (t: Throwable) {
      Log.w(TAG, "enum ifaces failed", t)
    }
    return null
  }
}
