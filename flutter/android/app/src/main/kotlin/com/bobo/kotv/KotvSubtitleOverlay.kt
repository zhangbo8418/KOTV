package com.bobo.kotv

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.TextView
import androidx.annotation.OptIn
import androidx.media3.common.text.Cue
import androidx.media3.common.text.CueGroup
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.text.TextOutput
import io.github.peerless2012.ass.media.AssHandler
import io.github.peerless2012.ass.media.AssHandlerConfig
import io.github.peerless2012.ass.media.type.AssRenderType
import io.github.peerless2012.ass.media.widget.AssSubtitleView

/**
 * 主/副字幕叠加层：普通 Cue 用 TextView；开启 libass 时叠 AssSubtitleView。
 */
@OptIn(UnstableApi::class)
class KotvSubtitleOverlay(context: Context) : FrameLayout(context) {
  private val primaryView =
    TextView(context).apply {
      setTextColor(Color.WHITE)
      setShadowLayer(3f, 1f, 1f, Color.BLACK)
      typeface = Typeface.DEFAULT_BOLD
      gravity = Gravity.CENTER_HORIZONTAL or Gravity.BOTTOM
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
      isFocusable = false
    }
  private val secondaryView =
    TextView(context).apply {
      setTextColor(Color.parseColor("#FFE082"))
      setShadowLayer(3f, 1f, 1f, Color.BLACK)
      typeface = Typeface.DEFAULT_BOLD
      gravity = Gravity.CENTER_HORIZONTAL or Gravity.TOP
      setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
      isFocusable = false
      visibility = View.GONE
    }

  private var assHandler: AssHandler? = null
  private var assView: AssSubtitleView? = null
  private var libassEnabled = false
  private var secondaryEnabled = false
  private var primaryBottomFraction = 0.08f
  private var secondaryTopFraction = 0.08f
  private var fontScale = 1.0f

  val secondaryTextOutput =
    TextOutput { group: CueGroup ->
      post { applyCues(secondaryView, group.cues) }
    }

  init {
    isFocusable = false
    importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    addView(
      primaryView,
      LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
        gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
        bottomMargin = dp(24)
        leftMargin = dp(16)
        rightMargin = dp(16)
      },
    )
    addView(
      secondaryView,
      LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
        gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
        topMargin = dp(24)
        leftMargin = dp(16)
        rightMargin = dp(16)
      },
    )
  }

  fun attachTo(host: ViewGroup) {
    if (parent === host) {
      bringToFront()
      return
    }
    (parent as? ViewGroup)?.removeView(this)
    host.addView(
      this,
      LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT),
    )
    bringToFront()
  }

  fun setPrimaryCues(cues: List<Cue>) {
    if (libassEnabled && assView != null) {
      // ASS 由 AssSubtitleView 渲染；主轨仍可显示非 ASS 文本轨。
      val textOnly = cues.filter { it.bitmap == null && !it.text.isNullOrBlank() }
      applyCues(primaryView, textOnly)
      return
    }
    applyCues(primaryView, cues)
  }

  fun setSecondaryEnabled(enabled: Boolean) {
    secondaryEnabled = enabled
    secondaryView.visibility = if (enabled) View.VISIBLE else View.GONE
    if (!enabled) secondaryView.text = ""
  }

  fun setStyle(fontScale: Float, primaryBottomFraction: Float, secondaryTopFraction: Float) {
    this.fontScale = fontScale.coerceIn(0.5f, 2.5f)
    this.primaryBottomFraction = primaryBottomFraction.coerceIn(0f, 0.4f)
    this.secondaryTopFraction = secondaryTopFraction.coerceIn(0f, 0.4f)
    primaryView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f * this.fontScale)
    secondaryView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f * this.fontScale)
    requestLayout()
  }

  fun setLibassEnabled(enabled: Boolean) {
    if (libassEnabled == enabled) return
    libassEnabled = enabled
    if (enabled) {
      ensureAss()
    } else {
      releaseAss()
    }
  }

  fun assHandlerOrNull(): AssHandler? = if (libassEnabled) assHandler else null

  fun onPrimaryPlayerCues(group: CueGroup) {
    setPrimaryCues(group.cues)
  }

  fun release() {
    releaseAss()
    primaryView.text = ""
    secondaryView.text = ""
  }

  override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
    super.onLayout(changed, left, top, right, bottom)
    val h = bottom - top
    if (h <= 0) return
    val primaryLp = primaryView.layoutParams as LayoutParams
    primaryLp.bottomMargin = (h * primaryBottomFraction).toInt().coerceAtLeast(dp(8))
    primaryView.layoutParams = primaryLp
    val secondaryLp = secondaryView.layoutParams as LayoutParams
    secondaryLp.topMargin = (h * secondaryTopFraction).toInt().coerceAtLeast(dp(8))
    secondaryView.layoutParams = secondaryLp
  }

  private fun ensureAss() {
    if (assHandler != null) return
    val handler =
      AssHandler(
        AssRenderType.OVERLAY_CANVAS,
        AssHandlerConfig(),
      )
    assHandler = handler
    val view = AssSubtitleView(context, handler)
    assView = view
    addView(
      view,
      0,
      LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT),
    )
  }

  private fun releaseAss() {
    try {
      assHandler?.release()
    } catch (_: Throwable) {
    }
    assHandler = null
    assView?.let { removeView(it) }
    assView = null
  }

  private fun applyCues(target: TextView, cues: List<Cue>) {
    if (cues.isEmpty()) {
      target.text = ""
      return
    }
    val sb = SpannableStringBuilder()
    for (cue in cues) {
      val text = cue.text
      if (text.isNullOrBlank()) continue
      if (sb.isNotEmpty()) sb.append('\n')
      if (text is Spanned) {
        sb.append(text)
      } else {
        sb.append(text)
      }
    }
    target.text = sb
  }

  private fun dp(v: Int): Int =
    (v * resources.displayMetrics.density + 0.5f).toInt()
}
