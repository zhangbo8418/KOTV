package com.bobo.kotv

/**
 * PCM 声道混合矩阵（源自 Media3 mpvplayer AudioChannelMix 公开源）。
 * 用于 Exo ChannelMixingAudioProcessor / 软 EQ 路径。
 */
object KotvAudioChannelMix {
  private const val MAX_MIX_CHANNEL_COUNT = 8
  private const val POWER_GAIN = 0.7071f
  private const val LOW_FREQUENCY_GAIN = 0.5f

  private val STEREO_LEFT =
    arrayOf(
      floatArrayOf(POWER_GAIN),
      floatArrayOf(1.0f, 0.0f),
      floatArrayOf(1.0f, 0.0f, POWER_GAIN),
      floatArrayOf(1.0f, 0.0f, POWER_GAIN, 0.0f),
      floatArrayOf(1.0f, 0.0f, POWER_GAIN, POWER_GAIN, 0.0f),
      floatArrayOf(1.0f, 0.0f, POWER_GAIN, LOW_FREQUENCY_GAIN, POWER_GAIN, 0.0f),
      floatArrayOf(1.0f, 0.0f, POWER_GAIN, LOW_FREQUENCY_GAIN, POWER_GAIN, 0.0f, POWER_GAIN),
      floatArrayOf(1.0f, 0.0f, POWER_GAIN, LOW_FREQUENCY_GAIN, POWER_GAIN, 0.0f, POWER_GAIN, 0.0f),
    )

  private val STEREO_RIGHT =
    arrayOf(
      floatArrayOf(POWER_GAIN),
      floatArrayOf(0.0f, 1.0f),
      floatArrayOf(0.0f, 1.0f, POWER_GAIN),
      floatArrayOf(0.0f, 1.0f, 0.0f, POWER_GAIN),
      floatArrayOf(0.0f, 1.0f, POWER_GAIN, 0.0f, POWER_GAIN),
      floatArrayOf(0.0f, 1.0f, POWER_GAIN, LOW_FREQUENCY_GAIN, 0.0f, POWER_GAIN),
      floatArrayOf(0.0f, 1.0f, POWER_GAIN, LOW_FREQUENCY_GAIN, 0.0f, POWER_GAIN, POWER_GAIN),
      floatArrayOf(0.0f, 1.0f, POWER_GAIN, LOW_FREQUENCY_GAIN, 0.0f, POWER_GAIN, 0.0f, POWER_GAIN),
    )

  private val MONO =
    arrayOf(
      floatArrayOf(1.0f),
      floatArrayOf(POWER_GAIN, POWER_GAIN),
      floatArrayOf(POWER_GAIN, POWER_GAIN, 1.0f),
      floatArrayOf(POWER_GAIN, POWER_GAIN, LOW_FREQUENCY_GAIN, LOW_FREQUENCY_GAIN),
      floatArrayOf(POWER_GAIN, POWER_GAIN, 1.0f, LOW_FREQUENCY_GAIN, LOW_FREQUENCY_GAIN),
      floatArrayOf(POWER_GAIN, POWER_GAIN, 1.0f, POWER_GAIN, LOW_FREQUENCY_GAIN, LOW_FREQUENCY_GAIN),
      floatArrayOf(
        POWER_GAIN,
        POWER_GAIN,
        1.0f,
        POWER_GAIN,
        LOW_FREQUENCY_GAIN,
        LOW_FREQUENCY_GAIN,
        LOW_FREQUENCY_GAIN,
      ),
      floatArrayOf(
        POWER_GAIN,
        POWER_GAIN,
        1.0f,
        POWER_GAIN,
        LOW_FREQUENCY_GAIN,
        LOW_FREQUENCY_GAIN,
        LOW_FREQUENCY_GAIN,
        LOW_FREQUENCY_GAIN,
      ),
    )

  fun mixStereoLeft(samples: FloatArray): Float = mix(samples, forCount(STEREO_LEFT, samples.size))

  fun mixStereoRight(samples: FloatArray): Float = mix(samples, forCount(STEREO_RIGHT, samples.size))

  fun mixMono(samples: FloatArray): Float = mix(samples, forCount(MONO, samples.size))

  fun createStereoMix(channelCount: Int, reverse: Boolean): Array<FloatArray> {
    checkMixChannelCount(channelCount)
    val mix = Array(channelCount) { FloatArray(channelCount) }
    val left = forCount(STEREO_LEFT, channelCount)
    val right = forCount(STEREO_RIGHT, channelCount)
    setGains(mix[0], if (reverse) right else left)
    setGains(mix[1], if (reverse) left else right)
    return mix
  }

  fun createMonoMix(channelCount: Int): Array<FloatArray> {
    checkMixChannelCount(channelCount)
    val gains = forCount(MONO, channelCount)
    val mix = Array(channelCount) { FloatArray(channelCount) }
    setGains(mix[0], gains)
    setGains(mix[1], gains)
    return mix
  }

  fun createFrontCenterGainMix(channelCount: Int, gain: Float): Array<FloatArray> {
    require(channelCount == 6 || channelCount == 8)
    require(gain.isFinite() && gain >= 0f)
    val mix = createIdentityMix(channelCount)
    mix[2][2] = gain
    return mix
  }

  fun createFrontBalanceMix(channelCount: Int, balance: Float): Array<FloatArray> {
    checkMixChannelCount(channelCount)
    require(balance.isFinite() && balance in -1f..1f)
    val mix = createIdentityMix(channelCount)
    mix[0][0] = if (balance > 0f) 1f - balance else 1f
    mix[1][1] = if (balance < 0f) 1f + balance else 1f
    return mix
  }

  fun compose(first: Array<FloatArray>, second: Array<FloatArray>): Array<FloatArray> {
    val channelCount = first.size
    require(second.size == channelCount)
    val result = Array(channelCount) { FloatArray(channelCount) }
    for (output in 0 until channelCount) {
      for (intermediate in 0 until channelCount) {
        val gain = second[output][intermediate]
        if (gain == 0f) continue
        for (input in 0 until channelCount) {
          result[output][input] += gain * first[intermediate][input]
        }
      }
    }
    return result
  }

  fun toChannelMixingCoeffs(mix: Array<FloatArray>): FloatArray {
    val n = mix.size
    val coeffs = FloatArray(n * n)
    for (out in 0 until n) {
      for (inp in 0 until n) {
        coeffs[out * n + inp] = mix[out][inp]
      }
    }
    return coeffs
  }

  private fun mix(samples: FloatArray, gains: FloatArray): Float {
    var value = 0f
    for (channel in samples.indices) value += gains[channel] * samples[channel]
    return value
  }

  private fun forCount(mixes: Array<FloatArray>, channelCount: Int): FloatArray {
    require(channelCount in 1..MAX_MIX_CHANNEL_COUNT)
    return mixes[channelCount - 1]
  }

  private fun checkMixChannelCount(channelCount: Int) {
    require(channelCount in 2..MAX_MIX_CHANNEL_COUNT)
  }

  private fun createIdentityMix(channelCount: Int): Array<FloatArray> {
    val mix = Array(channelCount) { FloatArray(channelCount) }
    for (channel in 0 until channelCount) mix[channel][channel] = 1f
    return mix
  }

  private fun setGains(output: FloatArray, gains: FloatArray) {
    System.arraycopy(gains, 0, output, 0, gains.size)
  }
}
