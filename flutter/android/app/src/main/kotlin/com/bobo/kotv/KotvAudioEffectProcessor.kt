package com.bobo.kotv

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import java.nio.ByteBuffer
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * PCM 响度归一 + 稳定量 + 限幅（boost / preamp 一并乘算）。
 * 直通时勿挂本处理器。
 */
@OptIn(UnstableApi::class)
class KotvAudioEffectProcessor : BaseAudioProcessor() {

  @Volatile private var cfg = Config.disabled()
  private var resetRequested = false
  private val loudness = LoudnessNormalizer()
  private val stabilizer = Stabilizer()
  private val limiter = Limiter()
  private var frame = FloatArray(0)

  data class Config(
    val loudness: Boolean = false,
    val stability: Int = 0,
    val boost: Int = 0,
    val preamp: Int = 0,
  ) {
    val boostGain: Float = gainFromMb(boost)
    val preampGain: Float = gainFromMb(preamp)
    val stabilityAmount: Float = stability.coerceIn(0, 100) / 100f

    fun isActive(): Boolean = loudness || stability > 0 || boost != 0 || preamp != 0

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
      cur.preamp != next.preamp
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
    if (settings.isActive()) {
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
    val peak = peakOf(samples)
    var gain =
      settings.preampGain *
        loudness.gain(samples, settings) *
        stabilizer.gain(peak, settings) *
        settings.boostGain
    val limit = settings.loudness || settings.stability > 0 || settings.boost > 0
    if (limit) gain = limiter.gain(peak, gain)
    for (i in samples.indices) {
      val s = sanitize(samples[i] * gain)
      samples[i] = if (limit) limiter.limit(s) else s
    }
  }

  private fun frameFor(channelCount: Int): FloatArray {
    if (frame.size != channelCount) frame = FloatArray(channelCount)
    return frame
  }

  private fun resetState() {
    loudness.reset()
    stabilizer.reset()
    limiter.reset()
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
          if (isLfe(ch, samples.size)) continue
          val s = samples[ch]
          sum += s * s
        }
        return sum / n
      }

      private fun isLfe(channel: Int, channelCount: Int): Boolean =
        channel == 3 && channelCount in 6..8
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

  companion object {
    private fun smoothingStep(sampleRate: Int, seconds: Float): Float =
      (1.0 - exp(-1.0 / (sampleRate * seconds))).toFloat()

    private fun peakOf(samples: FloatArray): Float {
      var peak = 0f
      for (s in samples) peak = max(peak, kotlin.math.abs(s))
      return peak
    }

    private fun sanitize(sample: Float): Float = if (sample.isFinite()) sample else 0f

    private fun toPcm16(sample: Float): Short {
      val s = sample.coerceIn(-1f, 1f)
      return if (s <= -1f) Short.MIN_VALUE else (s * Short.MAX_VALUE).roundToInt().toShort()
    }
  }
}
