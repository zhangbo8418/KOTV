package com.bobo.kotv

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
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
      visibility = View.GONE
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
  private var primaryPos = 100.0
  private var secondaryPos = 0.0

  val secondaryTextOutput =
    TextOutput { group: CueGroup ->
      post { applyCues(secondaryView, group.cues) }
    }

  init {
    isFocusable = false
    importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    addView(
      primaryView,
      LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply {
        gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
        bottomMargin = dp(24)
        leftMargin = dp(16)
        rightMargin = dp(16)
      },
    )
    addView(
      secondaryView,
      LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply {
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
    if (!enabled) {
      secondaryView.text = ""
      secondaryView.visibility = View.GONE
      return
    }
    // 开启副字幕但不强制显示空条：有内容时由 applyCues 再 VISIBLE。
    if (secondaryView.text.isNullOrBlank()) {
      secondaryView.visibility = View.GONE
    }
  }

  /**
   * @param primaryPos mpv 风格 0–150（100=底部默认）
   * @param secondaryPos 副字幕：0=顶部默认；>0 时按主字幕刻度换算 topMargin
   */
  fun setStyle(
    fontScale: Float,
    primaryPos: Double = 100.0,
    secondaryPos: Double = 0.0,
    color: String = "#FFFFFF",
    borderColor: String = "#000000",
    borderSize: Double = 2.0,
    bgColor: String = "#00000000",
    edgeType: String = "outline",
    shadowStrength: Double = 50.0,
    fontName: String = "default",
    fontPath: String = "",
  ) {
    this.fontScale = fontScale.coerceIn(0.5f, 2.5f)
    this.primaryPos = primaryPos.coerceIn(0.0, 150.0)
    this.secondaryPos = secondaryPos.coerceIn(0.0, 150.0)
    // pos100 → 约 8% 底边距；pos0 → 更大底边距（字幕上移）
    primaryBottomFraction = posToBottomFraction(this.primaryPos)
    secondaryTopFraction = posToTopFraction(this.secondaryPos)
    primaryView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f * this.fontScale)
    secondaryView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f * this.fontScale)
    val tf = resolveTypeface(fontName, fontPath)
    primaryView.typeface = Typeface.create(tf, Typeface.BOLD)
    secondaryView.typeface = Typeface.create(tf, Typeface.BOLD)
    val fg = parseColorSafe(color, Color.WHITE)
    val edge = parseColorSafe(borderColor, Color.BLACK)
    val radius = (borderSize.coerceIn(0.0, 8.0).toFloat() * resources.displayMetrics.density).coerceAtLeast(0f)
    primaryView.setTextColor(fg)
    applyEdge(primaryView, edgeType, edge, radius, shadowStrength)
    applyBg(primaryView, bgColor)
    // 副字幕保持偏黄可读，仅同步描边/背景强度
    applyEdge(secondaryView, edgeType, edge, radius, shadowStrength)
    applyBg(secondaryView, bgColor)
    requestLayout()
  }

  private fun resolveTypeface(name: String, path: String = ""): Typeface {
    val filePath = path.trim()
    if (filePath.isNotEmpty()) {
      try {
        val f = java.io.File(filePath)
        if (f.isFile && f.canRead()) {
          return Typeface.createFromFile(f)
        }
      } catch (_: Throwable) {
      }
    }
    return when (name.trim().lowercase()) {
      "sans", "sans-serif" -> Typeface.SANS_SERIF
      "serif" -> Typeface.SERIF
      "mono", "monospace" -> Typeface.MONOSPACE
      else -> Typeface.DEFAULT
    }
  }

  private fun applyEdge(
    view: TextView,
    edgeType: String,
    edge: Int,
    radius: Float,
    shadowStrength: Double = 50.0,
  ) {
    val type = edgeType.trim().lowercase()
    if (type == "none" || radius <= 0.1f || Color.alpha(edge) <= 0) {
      view.setShadowLayer(0f, 0f, 0f, Color.TRANSPARENT)
      return
    }
    val r = radius.coerceAtLeast(1f)
    val strength = (shadowStrength.coerceIn(0.0, 100.0) / 50.0).toFloat().coerceIn(0f, 2.5f)
    when (type) {
      "shadow" -> view.setShadowLayer(r * 1.4f * strength, r * 0.35f * strength, r * 0.35f * strength, edge)
      "raised" -> view.setShadowLayer(r * 0.9f * strength, -r * 0.25f * strength, -r * 0.25f * strength, edge)
      "depressed" -> view.setShadowLayer(r * 0.9f * strength, r * 0.25f * strength, r * 0.25f * strength, edge)
      else -> view.setShadowLayer(r * strength.coerceAtLeast(0.5f), 0f, 0f, edge) // outline
    }
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
    if (target === secondaryView && !secondaryEnabled) {
      target.text = ""
      target.visibility = View.GONE
      return
    }
    if (cues.isEmpty()) {
      target.text = ""
      target.visibility = View.GONE
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
    if (sb.isEmpty()) {
      target.text = ""
      target.visibility = View.GONE
      return
    }
    target.visibility = View.VISIBLE
    target.text = sb
  }

  private fun applyBg(view: TextView, raw: String) {
    val c = parseColorSafe(raw, Color.TRANSPARENT)
    if (Color.alpha(c) <= 0) {
      view.background = null
      view.setPadding(0, 0, 0, 0)
      return
    }
    val d =
      GradientDrawable().apply {
        setColor(c)
        cornerRadius = dp(6).toFloat()
      }
    view.background = d
    val padH = dp(10)
    val padV = dp(4)
    view.setPadding(padH, padV, padH, padV)
  }

  private fun posToBottomFraction(pos: Double): Float {
    val p = pos.coerceIn(0.0, 150.0)
    return when {
      p >= 100.0 -> ((150.0 - p) / 50.0 * 0.04 + 0.04).toFloat().coerceIn(0.02f, 0.12f)
      else -> ((100.0 - p) / 100.0 * 0.35 + 0.08).toFloat().coerceIn(0.08f, 0.45f)
    }
  }

  private fun posToTopFraction(pos: Double): Float {
    // 0=顶部默认；增大 pos 则下移（增大 topMargin）
    val p = pos.coerceIn(0.0, 150.0)
    return (0.04 + p / 150.0 * 0.4).toFloat().coerceIn(0.04f, 0.45f)
  }

  private fun parseColorSafe(raw: String, fallback: Int): Int {
    val s = raw.trim()
    if (s.isEmpty()) return fallback
    return try {
      Color.parseColor(if (s.startsWith("#")) s else "#$s")
    } catch (_: Throwable) {
      fallback
    }
  }

  private fun dp(v: Int): Int =
    (v * resources.displayMetrics.density + 0.5f).toInt()
}
