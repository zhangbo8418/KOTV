package com.bobo.kotv

import java.util.Locale

/** 系统 Locale → 首选字幕语言标签（含中文简繁脚本）。 */
object KotvLangUtil {
  private const val LANGUAGE_CHINESE = "zh"
  private const val SCRIPT_HANS = "Hans"
  private const val SCRIPT_HANT = "Hant"
  private const val TAG_HANS = "zh-Hans"
  private const val TAG_HANT = "zh-Hant"

  fun preferredTextLanguages(): Array<String> {
    val locale = Locale.getDefault()
    val tag = locale.toLanguageTag()
    val language = locale.language
    if (!isChinese(locale)) {
      return if (tag == language) arrayOf(language) else unique(tag, language)
    }
    return if (tag == language) {
      unique(chineseScript(locale), language)
    } else {
      unique(tag, chineseScript(locale), language)
    }
  }

  private fun isChinese(locale: Locale): Boolean = LANGUAGE_CHINESE == locale.language

  private fun isTraditionalChinese(locale: Locale): Boolean {
    val script = locale.script
    if (SCRIPT_HANT.equals(script, ignoreCase = true)) return true
    if (SCRIPT_HANS.equals(script, ignoreCase = true)) return false
    val country = locale.country
    return "TW".equals(country, ignoreCase = true) ||
      "HK".equals(country, ignoreCase = true) ||
      "MO".equals(country, ignoreCase = true)
  }

  private fun chineseScript(locale: Locale): String =
    if (isTraditionalChinese(locale)) TAG_HANT else TAG_HANS

  private fun unique(vararg languages: String): Array<String> {
    val result = ArrayList<String>()
    for (language in languages) {
      if (language.isNotEmpty() && !result.contains(language)) result.add(language)
    }
    return result.toTypedArray()
  }
}
