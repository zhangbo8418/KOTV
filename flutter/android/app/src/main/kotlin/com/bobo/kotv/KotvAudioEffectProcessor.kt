package com.bobo.kotv

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import java.nio.ByteBuffer
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * PCM：响度 / 稳定量 / boost / preamp / 声道模式 / 平衡 / 中置 / 可选软 EQ。
 * 直通时勿挂本处理器。
 */
@OptIn(UnstableApi::class)
class KotvAudioEffectProcessor : BaseAudioProcessor() {

  @Volatile private var cfg = Config.disabled()
  private var resetRequested = false
  private val loudness = LoudnessNormalizer()
  private val stabilizer = Stabilizer()
  private val limiter = Limiter()
  private val softwareEq = SoftwareEqualizer()
  private var frame = FloatArray(0)

  data class Config(
    val loudness: Boolean = false,
    val stability: Int = 0,
    val boost: Int = 0,
    val preamp: Int = 0,
    val centerGain: Int = 0,
    val balance: Int = 0,
    val channelMode: String = "auto",
    val softwareEqualizer: Boolean = false,
    val eqLevelsMb: ShortArray = ShortArray(0),
  ) {
    val boostGain: Float = gainFromMb(boost)
    val preampGain: Float = gainFromMb(preamp)
    val centerGainFactor: Float = gainFromMb(centerGain)
    val stabilityAmount: Float = stability.coerceIn(0, 100) / 100f

    fun isActive(channelCount: Int): Boolean =
      loudness ||
        stability > 0 ||
        boost != 0 ||
        preamp != 0 ||
        (centerGain > 0 && (channelCount == 6 || channelCount == 8)) ||
        (channelCount >= 2 && (balance != 0 || channelMode != "auto")) ||
        softwareEqualizer

    companion object {
      fun disabled() = Config()

      private fun gainFromMb(mb: Int): Float {
        if (mb == 0) return 1f
        return 10.0.pow(mb / 2000.0).toFloat()
      }
    }
  }

  @Synchronized
  fun setConfig(next: Config) {
    val cur = cfg
    if (cur.loudness != next.loudness ||
      cur.stability != next.stability ||
      cur.boost != next.boost ||
      cur.preamp != next.preamp ||
      cur.centerGain != next.centerGain ||
      cur.balance != next.balance ||
      cur.channelMode != next.channelMode ||
      cur.softwareEqualizer != next.softwareEqualizer ||
      !cur.eqLevelsMb.contentEquals(next.eqLevelsMb)
    ) {
      resetRequested = true
    }
    cfg = next
  }

  fun resetSettings() = setConfig(Config.disabled())

  override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
    val ok =
      inputAudioFormat.channelCount > 0 &&
        (inputAudioFormat.encoding == C.ENCODING_PCM_16BIT ||
          inputAudioFormat.encoding == C.ENCODING_PCM_FLOAT)
    if (!ok) return AudioProcessor.AudioFormat.NOT_SET
    val sampleRate = max(1, inputAudioFormat.sampleRate)
    limiter.configure(sampleRate)
    loudness.configure(sampleRate)
    return inputAudioFormat
  }

  override fun queueInput(inputBuffer: ByteBuffer) {
    if (!inputBuffer.hasRemaining()) return
    val remaining = inputBuffer.remaining()
    val bpf = inputAudioFormat.bytesPerFrame
    if (bpf <= 0 || remaining % bpf != 0) {
      throw IllegalStateException("Queued an incomplete frame.")
    }
    val output = replaceOutputBuffer(remaining)
    val settings = currentSettings()
    if (settings.isActive(inputAudioFormat.channelCount)) {
      processInput(inputBuffer, output, settings)
    } else {
      output.put(inputBuffer)
    }
    output.flip()
  }

  override fun onFlush(streamMetadata: AudioProcessor.StreamMetadata) {
    resetState()
  }

  override fun onReset() {
    resetState()
  }

  @Synchronized
  private fun currentSettings(): Config {
    val s = cfg
    if (resetRequested) resetState()
    resetRequested = false
    return s
  }

  private fun processInput(input: ByteBuffer, output: ByteBuffer, settings: Config) {
    val channels = inputAudioFormat.channelCount
    val samples = frameFor(channels)
    if (settings.softwareEqualizer) {
      softwareEq.configure(inputAudioFormat.sampleRate, channels, settings.eqLevelsMb)
    }
    if (inputAudioFormat.encoding == C.ENCODING_PCM_FLOAT) {
      while (input.hasRemaining()) {
        for (i in 0 until channels) samples[i] = sanitize(input.float)
        processFrame(samples, settings)
        for (s in samples) output.putFloat(s)
      }
    } else {
      while (input.hasRemaining()) {
        for (i in 0 until channels) samples[i] = input.short / 32768f
        processFrame(samples, settings)
        for (s in samples) output.putShort(toPcm16(s))
      }
    }
  }

  private fun processFrame(samples: FloatArray, settings: Config) {
    applyCenterGain(samples, settings)
    applyChannelMode(samples, settings.channelMode)
    applyBalance(samples, settings.balance, settings.channelMode)
    applyGain(samples, settings, limit = !settings.softwareEqualizer)
    if (settings.softwareEqualizer) {
      softwareEq.process(samples)
      applyOutputLimiter(samples, settings)
    }
  }

  private fun applyGain(samples: FloatArray, settings: Config, limit: Boolean) {
    val peak = peakOf(samples)
    var gain =
      settings.preampGain *
        loudness.gain(samples, settings) *
        stabilizer.gain(peak, settings) *
        settings.boostGain
    val shouldLimit =
      limit &&
        (settings.loudness || settings.stability > 0 || settings.boost > 0 ||
          settings.channelMode != "auto")
    if (shouldLimit) gain = limiter.gain(peak, gain)
    for (i in samples.indices) {
      val s = sanitize(samples[i] * gain)
      samples[i] = if (shouldLimit) limiter.limit(s) else s
    }
  }

  private fun applyOutputLimiter(samples: FloatArray, settings: Config) {
    val need =
      settings.loudness || settings.stability > 0 || settings.boost > 0 ||
        settings.eqLevelsMb.any { it > 0 }
    if (!need) return
    val gain = limiter.gain(peakOf(samples), 1f)
    for (i in samples.indices) samples[i] = limiter.limit(sanitize(samples[i] * gain))
  }

  private fun applyCenterGain(samples: FloatArray, settings: Config) {
    if (settings.centerGain <= 0) return
    if (samples.size != 6 && samples.size != 8) return
    samples[2] = sanitize(samples[2] * settings.centerGainFactor)
  }

  private fun applyChannelMode(samples: FloatArray, mode: String) {
    when (mode) {
      "stereo" -> {
        if (samples.size < 2) return
        val left = KotvAudioChannelMix.mixStereoLeft(samples)
        val right = KotvAudioChannelMix.mixStereoRight(samples)
        samples[0] = sanitize(left)
        samples[1] = sanitize(right)
        for (i in 2 until samples.size) samples[i] = 0f
      }
      "mono" -> {
        if (samples.size < 2) return
        val mono = sanitize(KotvAudioChannelMix.mixMono(samples))
        samples[0] = mono
        samples[1] = mono
        for (i in 2 until samples.size) samples[i] = 0f
      }
      "reverse" -> {
        if (samples.size < 2) return
        val left = KotvAudioChannelMix.mixStereoLeft(samples)
        val right = KotvAudioChannelMix.mixStereoRight(samples)
        samples[0] = sanitize(right)
        samples[1] = sanitize(left)
        for (i in 2 until samples.size) samples[i] = 0f
      }
    }
  }

  private fun applyBalance(samples: FloatArray, balance: Int, mode: String) {
    if (balance == 0 || mode == "mono" || samples.size < 2) return
    samples[0] *= if (balance > 0) 1f - balance / 100f else 1f
    samples[1] *= if (balance < 0) 1f + balance / 100f else 1f
  }

  private fun frameFor(channelCount: Int): FloatArray {
    if (frame.size != channelCount) frame = FloatArray(channelCount)
    return frame
  }

  private fun resetState() {
    loudness.reset()
    stabilizer.reset()
    limiter.reset()
    softwareEq.reset()
  }

  private class LoudnessNormalizer {
    private var power = TARGET * TARGET
    private var gain = 1f
    private var powerStep = 1f
    private var attackStep = 1f
    private var releaseStep = 1f

    fun configure(sampleRate: Int) {
      powerStep = smoothingStep(sampleRate, 10f)
      attackStep = smoothingStep(sampleRate, 1f)
      releaseStep = smoothingStep(sampleRate, 5f)
    }

    fun gain(samples: FloatArray, config: Config): Float {
      if (!config.loudness) return 1f
      update(loudnessPower(samples))
      return gain
    }

    fun reset() {
      power = TARGET * TARGET
      gain = 1f
    }

    private fun update(currentPower: Float) {
      if (currentPower < GATE_POWER) return
      power += (currentPower - power) * powerStep
      var target = TARGET / sqrt(max(power, GATE_POWER))
      target = target.coerceIn(MIN_GAIN, MAX_GAIN)
      val step = if (target < gain) attackStep else releaseStep
      gain += (target - gain) * step
    }

    companion object {
      private const val TARGET = 0.125f
      private const val GATE_POWER = 0.000004f
      private const val MIN_GAIN = 0.5f
      private const val MAX_GAIN = 4.0f

      private fun loudnessPower(samples: FloatArray): Float {
        val n = min(2, samples.size)
        if (n <= 0) return 0f
        var sum = 0f
        for (ch in 0 until n) {
          if (ch == 3 && samples.size in 6..8) continue
          val s = samples[ch]
          sum += s * s
        }
        return sum / n
      }
    }
  }

  private class Stabilizer {
    private var envelope = INITIAL_ENVELOPE
    private var gain = 1f

    fun gain(peak: Float, config: Config): Float {
      if (config.stability <= 0) return 1f
      update(peak, config.stabilityAmount)
      return gain
    }

    fun reset() {
      envelope = INITIAL_ENVELOPE
      gain = 1f
    }

    private fun update(peak: Float, intensity: Float) {
      val targetEnv = max(peak, MIN_ENVELOPE)
      val envStep = if (targetEnv > envelope) 0.08f else 0.002f
      envelope += (targetEnv - envelope) * envStep
      var targetGain = 0.22f / max(envelope, MIN_ENVELOPE)
      val maxGain = 1f + 2.2f * intensity
      val minGain = 1f - 0.65f * intensity
      targetGain = targetGain.coerceIn(minGain, maxGain)
      targetGain = 1f + (targetGain - 1f) * intensity
      val gainStep = if (targetGain < gain) 0.025f else 0.001f
      gain += (targetGain - gain) * gainStep
    }

    companion object {
      private const val INITIAL_ENVELOPE = 0.08f
      private const val MIN_ENVELOPE = 0.02f
    }
  }

  private class Limiter {
    private var envelope = 0f
    private var releaseStep = 1f

    fun configure(sampleRate: Int) {
      releaseStep = smoothingStep(sampleRate, RELEASE_SECONDS)
    }

    fun gain(peak: Float, gain: Float): Float {
      val amplified = peak * gain
      if (amplified > envelope) envelope = amplified
      else envelope += (amplified - envelope) * releaseStep
      return if (envelope > LIMIT) gain * LIMIT / envelope else gain
    }

    fun limit(sample: Float): Float = sample.coerceIn(-LIMIT, LIMIT)

    fun reset() {
      envelope = 0f
    }

    companion object {
      private const val LIMIT = 0.98f
      private const val RELEASE_SECONDS = 0.05f
    }
  }

  /** 标准 10 段 peaking EQ（API &lt; 28 时用）。 */
  private class SoftwareEqualizer {
    private val centersHz =
      doubleArrayOf(32.0, 64.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0)
    private val a1 = DoubleArray(centersHz.size)
    private val a2 = DoubleArray(centersHz.size)
    private val b0 = DoubleArray(centersHz.size)
    private val b1 = DoubleArray(centersHz.size)
    private val b2 = DoubleArray(centersHz.size)
    private val active = BooleanArray(centersHz.size)
    private var x1 = Array(centersHz.size) { DoubleArray(0) }
    private var x2 = Array(centersHz.size) { DoubleArray(0) }
    private var y1 = Array(centersHz.size) { DoubleArray(0) }
    private var y2 = Array(centersHz.size) { DoubleArray(0) }
    private var sampleRate = 0
    private var channelCount = 0
    private var levels: ShortArray? = null

    fun configure(sampleRate: Int, channelCount: Int, levels: ShortArray) {
      if (sampleRate <= 0 || channelCount <= 0) return
      val rateChanged = this.sampleRate != sampleRate
      val channelsChanged = this.channelCount != channelCount
      val levelsChanged = this.levels == null || !this.levels.contentEquals(levels)
      if (!rateChanged && !channelsChanged && !levelsChanged) return
      if (channelsChanged) allocate(channelCount)
      val next = levels.copyOf(centersHz.size)
      for (i in next.indices) {
        if (rateChanged || this.levels == null || this.levels!![i] != next[i]) {
          setBand(i, next[i], sampleRate)
        }
      }
      if (rateChanged && !channelsChanged) clearState()
      this.levels = next
      this.sampleRate = sampleRate
      this.channelCount = channelCount
    }

    fun process(samples: FloatArray) {
      val channels = min(samples.size, channelCount)
      for (ch in 0 until channels) samples[ch] = processChannel(samples[ch], ch)
    }

    fun reset() {
      clearState()
    }

    private fun processChannel(sample: Float, channel: Int): Float {
      var value = sample.toDouble()
      for (band in active.indices) {
        if (active[band]) value = processBand(value, band, channel)
      }
      return if (value.isFinite()) value.toFloat() else 0f
    }

    private fun processBand(value: Double, band: Int, channel: Int): Double {
      val output =
        b0[band] * value + b1[band] * x1[band][channel] + b2[band] * x2[band][channel] -
          a1[band] * y1[band][channel] - a2[band] * y2[band][channel]
      x2[band][channel] = x1[band][channel]
      x1[band][channel] = value
      y2[band][channel] = y1[band][channel]
      y1[band][channel] = output
      return output
    }

    private fun setBand(index: Int, level: Short, sampleRate: Int) {
      val frequency = centersHz[index]
      if (level.toInt() == 0 || frequency >= sampleRate * 0.5) {
        active[index] = false
        clearBand(index)
        return
      }
      val amplitude = 10.0.pow(level / 4000.0)
      val omega = 2.0 * PI * frequency / sampleRate
      val alpha = sin(omega) / (2.0 * Q)
      val a0 = 1.0 + alpha / amplitude
      b0[index] = (1.0 + alpha * amplitude) / a0
      b1[index] = -2.0 * cos(omega) / a0
      b2[index] = (1.0 - alpha * amplitude) / a0
      a1[index] = -2.0 * cos(omega) / a0
      a2[index] = (1.0 - alpha / amplitude) / a0
      active[index] = true
    }

    private fun allocate(channelCount: Int) {
      this.channelCount = channelCount
      x1 = Array(centersHz.size) { DoubleArray(channelCount) }
      x2 = Array(centersHz.size) { DoubleArray(channelCount) }
      y1 = Array(centersHz.size) { DoubleArray(channelCount) }
      y2 = Array(centersHz.size) { DoubleArray(channelCount) }
    }

    private fun clearState() {
      for (band in active.indices) clearBand(band)
    }

    private fun clearBand(band: Int) {
      if (x1[band].isEmpty()) return
      x1[band].fill(0.0)
      x2[band].fill(0.0)
      y1[band].fill(0.0)
      y2[band].fill(0.0)
    }

    companion object {
      private const val Q = 1.0
    }
  }

  companion object {
    private fun smoothingStep(sampleRate: Int, seconds: Float): Float =
      (1.0 - exp(-1.0 / (sampleRate * seconds))).toFloat()

    private fun peakOf(samples: FloatArray): Float {
      var peak = 0f
      for (s in samples) peak = max(peak, abs(s))
      return peak
    }

    private fun sanitize(sample: Float): Float = if (sample.isFinite()) sample else 0f

    private fun toPcm16(sample: Float): Short {
      val s = sample.coerceIn(-1f, 1f)
      return if (s <= -1f) Short.MIN_VALUE else (s * Short.MAX_VALUE).roundToInt().toShort()
    }

    /** 对白增强：按中心频率叠 mB（与 AudioSetting.getDialogueLevel 一致）。 */
    fun dialogueLevelMb(milliHz: Int, dialogue: Int): Float {
      if (dialogue <= 0) return 0f
      val hz = milliHz / 1000
      if (hz <= 0) return 0f
      if (hz < 180) return -180f * dialogue / 100f
      if (hz < 500) return -80f * dialogue / 100f
      val octaves = abs(ln(hz / 2500.0) / ln(2.0))
      val weight = max(0.0, 1.0 - octaves / 2.0)
      return (weight * 650.0 * dialogue / 100.0).toFloat()
    }
  }
}
