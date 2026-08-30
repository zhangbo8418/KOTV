package com.bobo.kotv

import android.os.Build
import android.view.View
import android.view.ViewGroup

/**
 * Flutter Hybrid / VD 的 PlatformView 外包一层 [io.flutter.plugin.platform.PlatformViewWrapper]
 * 默认 `focusable=true`，在 TV 盒上会吃掉 DPAD，焦点进得去出不来。
 * 宿主视图与向上若干层父布局一律关掉焦点。
 */
internal fun View.stripPlatformViewFocus(maxParents: Int = 8) {
  fun clear(v: View) {
    v.isFocusable = false
    v.isFocusableInTouchMode = false
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      v.defaultFocusHighlightEnabled = false
    }
    if (v is ViewGroup) {
      v.descendantFocusability = ViewGroup.FOCUS_BLOCK_DESCENDANTS
    }
  }
  clear(this)
  var p = parent
  var depth = 0
  while (p is View && depth < maxParents) {
    clear(p)
    p = p.parent
    depth++
  }
}
