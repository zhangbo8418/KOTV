package com.bobo.kotv.exo

import android.content.Context
import android.opengl.GLES20
import androidx.annotation.OptIn
import androidx.media3.common.Effect
import androidx.media3.common.VideoFrameProcessingException
import androidx.media3.common.util.GlProgram
import androidx.media3.common.util.GlUtil
import androidx.media3.common.util.Size
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.BaseGlShaderProgram
import androidx.media3.effect.GlEffect
import androidx.media3.effect.GlShaderProgram
import androidx.media3.exoplayer.ExoPlayer

/**
 * Exo Surface/Texture 共用画面调色：Media3 [ExoPlayer.setVideoEffects]。
 * 数值约定与 Dart [KotvVideoEq] 一致：brightness/contrast/… ∈ [-100,100]，0 中性；
 * sharpness ∈ [0,100]；gamma 在引擎内映射为约 0.5–1.5。
 *
 * 限制：隧道模式、HDR 下效果不可用。
 * 锐度/阴影为近似实现。
 */
@OptIn(UnstableApi::class)
class KotvExoVideoEqController {
  private val colorTone = ColorToneEffect()
  private val detail = DetailEffect()
  private val effects: List<Effect> = listOf(colorTone, detail)
  private var configured = false

  data class Params(
    val brightness: Int = 0,
    val contrast: Int = 0,
    val saturation: Int = 0,
    val gamma: Int = 0,
    val hue: Int = 0,
    val temperature: Int = 0,
    val sharpness: Int = 0,
    val shadow: Int = 0,
  ) {
    val enabled: Boolean
      get() =
        brightness != 0 ||
          contrast != 0 ||
          saturation != 0 ||
          gamma != 0 ||
          hue != 0 ||
          temperature != 0 ||
          sharpness != 0 ||
          shadow != 0
  }

  fun apply(player: ExoPlayer?, params: Params, tunneling: Boolean) {
    if (player == null) return
    if (tunneling || !params.enabled) {
      try {
        // 空列表也要在首次 prepare 前调用，以便建好 effects 管线供后续热更。
        player.setVideoEffects(emptyList())
        configured = false
      } catch (_: Throwable) {
        configured = false
      }
      return
    }
    colorTone.setParams(params)
    detail.setParams(params)
    try {
      player.setVideoEffects(effects)
      configured = true
    } catch (t: Throwable) {
      configured = false
    }
  }

  fun clear(player: ExoPlayer?) {
    if (player == null) return
    try {
      player.setVideoEffects(emptyList())
    } catch (_: Throwable) {
    }
    configured = false
  }
}

@OptIn(UnstableApi::class)
private abstract class VideoAdjustProgram(
  useHdr: Boolean,
  fragmentShader: String,
) : BaseGlShaderProgram(/* useHighPrecisionColorComponents= */ false, /* texturePoolCapacity= */ 1) {
  protected val glProgram: GlProgram

  init {
    if (useHdr) {
      throw VideoFrameProcessingException("Video EQ does not support HDR")
    }
    try {
      glProgram = GlProgram(VERTEX, fragmentShader)
      glProgram.setBufferAttribute(
        "aFramePosition",
        GlUtil.getNormalizedCoordinateBounds(),
        GlUtil.HOMOGENEOUS_COORDINATE_VECTOR_SIZE,
      )
    } catch (e: GlUtil.GlException) {
      throw VideoFrameProcessingException(e)
    }
  }

  override fun configure(inputWidth: Int, inputHeight: Int): Size = Size(inputWidth, inputHeight)

  override fun drawFrame(inputTexId: Int, presentationTimeUs: Long) {
    try {
      glProgram.use()
      glProgram.setSamplerTexIdUniform("uTexSampler", inputTexId, 0)
      bindUniforms()
      glProgram.bindAttributesAndUniforms()
      GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    } catch (e: GlUtil.GlException) {
      throw VideoFrameProcessingException(e, presentationTimeUs)
    }
  }

  protected abstract fun bindUniforms()

  override fun release() {
    super.release()
    try {
      glProgram.delete()
    } catch (e: GlUtil.GlException) {
      throw VideoFrameProcessingException(e)
    }
  }

  companion object {
    private const val VERTEX = """
attribute vec4 aFramePosition;
varying vec2 vTexSamplingCoord;
void main() {
  gl_Position = aFramePosition;
  vTexSamplingCoord = aFramePosition.xy * 0.5 + 0.5;
}
"""
  }
}

@OptIn(UnstableApi::class)
private class ColorToneEffect : GlEffect {
  @Volatile private var matrix = IDENTITY
  @Volatile private var gamma = 1f
  @Volatile private var hue = 0f
  @Volatile private var noOp = true

  fun setParams(p: KotvExoVideoEqController.Params) {
    val sat = 1f + p.saturation.coerceIn(-100, 100) / 100f
    val con = 1f + p.contrast.coerceIn(-100, 100) / 100f
    val bri = p.brightness.coerceIn(-100, 100) / 100f
    val temp = p.temperature.coerceIn(-100, 100).toFloat()
    // 色温：正偏暖（红↑蓝↓），按 redGain/blueGain 量级缩放。
    val redGain = if (temp >= 0f) 1f + temp * 0.0015f else 1f + temp * 0.0012f
    val blueGain = if (temp >= 0f) 1f - temp * 0.0012f else 1f - temp * 0.0015f
    val invSat = 1f - sat
    val offset = bri + 0.5f * (1f - con)
    val lr = 0.2126f
    val lg = 0.7152f
    val lb = 0.0722f
    matrix =
      floatArrayOf(
        // column-major，ColorToneAdjustEffect 矩阵约定
        (lr * invSat + sat) * con * redGain,
        (lr * invSat) * con,
        (lr * invSat) * con * blueGain,
        0f,
        (lg * invSat) * con * redGain,
        (lg * invSat + sat) * con,
        (lg * invSat) * con * blueGain,
        0f,
        (lb * invSat) * con * redGain,
        (lb * invSat) * con,
        (lb * invSat + sat) * con * blueGain,
        0f,
        offset * redGain,
        offset,
        offset * blueGain,
        1f,
      )
    // Dart gamma ±100 → 约 0.5–1.5
    gamma = (1f + p.gamma.coerceIn(-100, 100) / 200f).coerceIn(0.5f, 1.5f)
    hue = p.hue.coerceIn(-100, 100) * 1.8f // ±100 → 约 ±180°
    noOp =
      p.brightness == 0 &&
        p.contrast == 0 &&
        p.saturation == 0 &&
        p.gamma == 0 &&
        p.hue == 0 &&
        p.temperature == 0
  }

  override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram =
    ColorToneProgram(useHdr, this)

  override fun isNoOp(inputWidth: Int, inputHeight: Int): Boolean = noOp

  fun matrix(): FloatArray = matrix

  fun gamma(): Float = gamma

  fun hue(): Float = hue

  companion object {
    private val IDENTITY =
      floatArrayOf(
        1f, 0f, 0f, 0f,
        0f, 1f, 0f, 0f,
        0f, 0f, 1f, 0f,
        0f, 0f, 0f, 1f,
      )
  }
}

@OptIn(UnstableApi::class)
private class ColorToneProgram(
  useHdr: Boolean,
  private val effect: ColorToneEffect,
) : VideoAdjustProgram(useHdr, FRAGMENT) {
  override fun bindUniforms() {
    glProgram.setFloatsUniform("uColorMatrix", effect.matrix())
    glProgram.setFloatUniform("uGamma", effect.gamma())
    glProgram.setFloatUniform("uHue", effect.hue())
  }

  companion object {
    private const val FRAGMENT = """
precision highp float;
uniform sampler2D uTexSampler;
uniform mat4 uColorMatrix;
uniform float uGamma;
uniform float uHue;
varying vec2 vTexSamplingCoord;
vec3 rotateHue(vec3 color, float hue) {
  float angle = radians(hue);
  float s = sin(angle);
  float c = cos(angle);
  float y = dot(color, vec3(0.299, 0.587, 0.114));
  float i = dot(color, vec3(0.596, -0.274, -0.322));
  float q = dot(color, vec3(0.211, -0.523, 0.312));
  float ii = i * c - q * s;
  float qq = i * s + q * c;
  return clamp(vec3(y + 0.956 * ii + 0.621 * qq, y - 0.272 * ii - 0.647 * qq, y - 1.106 * ii + 1.703 * qq), 0.0, 1.0);
}
void main() {
  vec4 sample = texture2D(uTexSampler, vTexSamplingCoord);
  vec3 color = clamp((uColorMatrix * vec4(sample.rgb, 1.0)).rgb, 0.0, 1.0);
  if (abs(uGamma - 1.0) > 0.0001) color = pow(color, vec3(1.0 / max(uGamma, 0.0001)));
  if (abs(uHue) > 0.0001) color = rotateHue(color, uHue);
  gl_FragColor = vec4(color, sample.a);
}
"""
  }
}

@OptIn(UnstableApi::class)
private class DetailEffect : GlEffect {
  @Volatile private var sharpness = 0f
  @Volatile private var threshold = 0.03f
  @Volatile private var shadowLift = 0f
  @Volatile private var noOp = true

  fun setParams(p: KotvExoVideoEqController.Params) {
    sharpness = (p.sharpness.coerceIn(0, 100) / 100f * 1.2f)
    shadowLift = (p.shadow.coerceIn(-100, 100) / 100f * 0.35f).coerceAtLeast(0f)
    noOp = sharpness <= 0.0001f && shadowLift <= 0.0001f
  }

  override fun toGlShaderProgram(context: Context, useHdr: Boolean): GlShaderProgram =
    DetailProgram(useHdr, this)

  override fun isNoOp(inputWidth: Int, inputHeight: Int): Boolean = noOp

  fun sharpness(): Float = sharpness

  fun threshold(): Float = threshold

  fun shadowLift(): Float = shadowLift
}

@OptIn(UnstableApi::class)
private class DetailProgram(
  useHdr: Boolean,
  private val effect: DetailEffect,
) : VideoAdjustProgram(useHdr, FRAGMENT) {
  private var texelW = 1f
  private var texelH = 1f

  override fun configure(inputWidth: Int, inputHeight: Int): Size {
    texelW = 1f / inputWidth.coerceAtLeast(1)
    texelH = 1f / inputHeight.coerceAtLeast(1)
    return super.configure(inputWidth, inputHeight)
  }

  override fun bindUniforms() {
    glProgram.setFloatsUniform("uTexelSize", floatArrayOf(texelW, texelH))
    glProgram.setFloatUniform("uSharpness", effect.sharpness())
    glProgram.setFloatUniform("uThreshold", effect.threshold())
    glProgram.setFloatUniform("uShadowLift", effect.shadowLift())
  }

  companion object {
    private const val FRAGMENT = """
precision highp float;
uniform sampler2D uTexSampler;
uniform vec2 uTexelSize;
uniform float uSharpness;
uniform float uThreshold;
uniform float uShadowLift;
varying vec2 vTexSamplingCoord;
const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);
const float SHADOW_START = 0.08;
const float SHADOW_END = 0.55;
void main() {
  vec4 center = texture2D(uTexSampler, vTexSamplingCoord);
  vec3 color = center.rgb;
  if (uSharpness > 0.0) {
    vec3 left = texture2D(uTexSampler, vTexSamplingCoord + vec2(-uTexelSize.x, 0.0)).rgb;
    vec3 right = texture2D(uTexSampler, vTexSamplingCoord + vec2(uTexelSize.x, 0.0)).rgb;
    vec3 up = texture2D(uTexSampler, vTexSamplingCoord + vec2(0.0, -uTexelSize.y)).rgb;
    vec3 down = texture2D(uTexSampler, vTexSamplingCoord + vec2(0.0, uTexelSize.y)).rgb;
    vec3 edge = color * 4.0 - left - right - up - down;
    float edgeStrength = max(max(abs(edge.r), abs(edge.g)), abs(edge.b));
    float mask = smoothstep(uThreshold, uThreshold * 2.0 + 0.0001, edgeStrength);
    color = clamp(color + edge * uSharpness * mask, 0.0, 1.0);
  }
  if (uShadowLift > 0.0) {
    float luma = dot(color, LUMA);
    float shadow = 1.0 - smoothstep(SHADOW_START, SHADOW_END, luma);
    color = clamp(color + (1.0 - color) * uShadowLift * shadow, 0.0, 1.0);
  }
  gl_FragColor = vec4(color, center.a);
}
"""
  }
}
