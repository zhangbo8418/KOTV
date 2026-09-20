package com.bobo.kotv

import java.util.Locale

/** 系统 Locale → 首选字幕语言标签与匹配打分（含中文简繁脚本）。 */
object KotvLangUtil {
  private const val SCORE_EXACT = 400
  private const val SCORE_SUBTAG = 300
  private const val SCORE_PRIMARY = 200
  private const val SCORE_RELATED = 100
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

  fun preferredTextLanguageScore(languageTag: String?): Int {
    val locale = Locale.getDefault()
    val preferred = normalize(locale.toLanguageTag())
    val language = normalize(languageTag)
    if (language.isEmpty()) return 0
    if (language == preferred) return SCORE_EXACT
    if (isChinese(locale)) return chineseScore(locale, language)
    return languageScore(preferred, locale.language, language)
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

  private fun chineseScore(locale: Locale, language: String): Int {
    val trackLocale = Locale.forLanguageTag(language)
    if (LANGUAGE_CHINESE != trackLocale.language) return 0
    if (language == LANGUAGE_CHINESE) return SCORE_PRIMARY
    return if (isTraditionalChinese(locale) == isTraditionalChinese(trackLocale)) {
      SCORE_SUBTAG
    } else {
      SCORE_RELATED
    }
  }

  private fun languageScore(preferred: String, preferredLanguage: String, language: String): Int {
    val trackLanguage = Locale.forLanguageTag(language).language
    if (preferredLanguage != trackLanguage) return 0
    return if (isTagPrefix(preferred, language) || isTagPrefix(language, preferred)) {
      SCORE_SUBTAG
    } else {
      SCORE_PRIMARY
    }
  }

  private fun isTagPrefix(tag: String, prefix: String): Boolean =
    tag == prefix || tag.startsWith("$prefix-")

  private fun normalize(language: String?): String =
    language?.trim()?.replace('_', '-')?.lowercase(Locale.ROOT).orEmpty()

  private fun unique(vararg languages: String): Array<String> {
    val result = ArrayList<String>()
    for (language in languages) {
      if (language.isNotEmpty() && !result.contains(language)) result.add(language)
    }
    return result.toTypedArray()
  }
}
