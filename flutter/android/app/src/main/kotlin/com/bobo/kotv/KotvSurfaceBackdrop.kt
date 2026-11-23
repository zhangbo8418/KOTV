package com.bobo.kotv

import android.graphics.Color
import android.graphics.PixelFormat
import android.os.Build
import android.view.Surface
import android.view.SurfaceControl
import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.annotation.RequiresApi

/**
 * 视频 SurfaceView 自身层级下的黑底（API 29+；更低版本不做事）。
 *
 * MediaOverlay 的 SurfaceView 出第一帧前没有缓冲，系统自带的背景层又沉在窗口最底下，
 * 这块区域会透出 Flutter 底层未刷新的内容：起播前滑动重影、全屏加载透出详情页。
 * 黑底挂成视频 SurfaceControl 的子层（z=-1）：始终在画面之下、Flutter 底层之上，随视频移动和裁剪；
 * 用自己的 Surface 画，不占用播放器的 EGL / 解码 Surface。出画后被不透明的视频层完全遮住。
 */
internal class KotvSurfaceBackdrop(private val view: SurfaceView) : SurfaceHolder.Callback {
  private var layer: SurfaceControl? = null
  private var surface: Surface? = null

  override fun surfaceCreated(holder: SurfaceHolder) {}

  override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) attach(width, height)
  }

  override fun surfaceDestroyed(holder: SurfaceHolder) {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) detach()
  }

  @RequiresApi(Build.VERSION_CODES.Q)
  private fun attach(width: Int, height: Int) {
    detach()
    if (width <= 0 || height <= 0) return
    try {
      val sc = SurfaceControl.Builder()
        .setName("KotvVideoBackdrop")
        .setParent(view.surfaceControl)
        .setBufferSize(width, height)
        .setFormat(PixelFormat.RGB_565)
        .setOpaque(true)
        .build()
      layer = sc
      // Surface 留到 detach 再释放：提前断开生产端，已排队的黑帧可能被丢掉。
      val s = Surface(sc)
      surface = s
      val canvas = s.lockCanvas(null)
      canvas.drawColor(Color.BLACK)
      s.unlockCanvasAndPost(canvas)
      SurfaceControl.Transaction().use { it.setLayer(sc, -1).setVisibility(sc, true).apply() }
    } catch (_: Throwable) {
      detach()
    }
  }

  @RequiresApi(Build.VERSION_CODES.Q)
  private fun detach() {
    val sc = layer ?: return
    layer = null
    try {
      SurfaceControl.Transaction().use { it.reparent(sc, null).apply() }
    } catch (_: Throwable) {
    }
    surface?.release()
    surface = null
    sc.release()
  }
}
