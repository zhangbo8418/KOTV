package com.bobo.kotv

import android.os.Build
import android.view.View
import android.view.ViewGroup

/**
 * Flutter Hybrid / VD 的 PlatformView 外包一层 PlatformViewWrapper，默认 focusable，
 * 在安卓盒子上会吃掉 DPAD。只关掉「宿主 + PlatformView 包装层」的焦点，
 * 切勿沿父链爬到 FlutterView / 内容根（否则整页 TvFocus 进不去也出不来）。
 */
internal fun View.stripPlatformViewFocus(maxParents: Int = 6) {
  fun clearLeaf(v: View) {
    v.isFocusable = false
    v.isFocusableInTouchMode = false
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      v.defaultFocusHighlightEnabled = false
    }
  }

  fun clearHost(v: ViewGroup) {
    clearLeaf(v)
    v.descendantFocusability = ViewGroup.FOCUS_BLOCK_DESCENDANTS
  }

  if (this is ViewGroup) clearHost(this) else clearLeaf(this)

  var p = parent
  var depth = 0
  while (p is View && depth < maxParents) {
    val name = p.javaClass.name
    val wrapper =
      name.contains("PlatformView") ||
        name.contains("FlutterMutatorView") ||
        name.endsWith(".PlatformViewWrapper")
    if (!wrapper) break
    if (p is ViewGroup) clearHost(p) else clearLeaf(p)
    p = p.parent
    depth++
  }
}
