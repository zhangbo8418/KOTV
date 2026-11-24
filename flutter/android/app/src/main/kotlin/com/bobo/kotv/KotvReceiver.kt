package com.bobo.kotv

import android.content.BroadcastReceiver
import android.content.Context
import android.content.IntentFilter
import android.os.Build

/**
 * 注册只收本应用广播的接收器。
 *
 * 不用 ContextCompat.registerReceiver：它在 API 33 以下按 getPackageName() 拼权限名校验，
 * 爬虫伪装包名期间会拼出 com.fongmi.android.tv.… 而抛异常（Activity 起不来）。
 */
internal fun Context.registerLocalReceiver(receiver: BroadcastReceiver, filter: IntentFilter) {
  if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
    registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
  } else {
    @Suppress("UnspecifiedRegisterReceiverFlag")
    registerReceiver(receiver, filter)
  }
}
