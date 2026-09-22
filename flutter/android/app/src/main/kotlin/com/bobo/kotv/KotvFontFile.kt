package com.bobo.kotv

import java.io.File
import java.io.RandomAccessFile
import java.nio.charset.Charset

/**
 * 从 TTF / OTF / TTC 读取字体族名（OpenType `name` 表）。
 *
 * `sub-font` / libass 按族名匹配字体，文件名（如 `NotoSansCJK-Regular`）通常不是族名
 * （`Noto Sans CJK SC`），直接用文件名会匹配失败退回默认字体。
 * 优先 nameID 16（Typographic Family），其次 nameID 1（Font Family）；TTC 取首个 face。
 */
object KotvFontFile {
  private const val TAG_NAME = 0x6E616D65 // 'name'
  private const val TAG_TTCF = 0x74746366 // 'ttcf'

  @JvmStatic
  fun familyName(file: File): String? {
    if (!file.isFile || !file.canRead()) return null
    return try {
      RandomAccessFile(file, "r").use { raf -> readFamily(raf) }
    } catch (_: Throwable) {
      null
    }
  }

  private fun readFamily(raf: RandomAccessFile): String? {
    var offset = 0L
    val magic = readU32(raf, 0)
    if (magic == TAG_TTCF.toLong()) {
      val numFonts = readU32(raf, 8)
      if (numFonts <= 0) return null
      offset = readU32(raf, 12)
    }
    val numTables = readU16(raf, offset + 4)
    var nameOffset = -1L
    var nameLength = 0L
    for (i in 0 until numTables) {
      val rec = offset + 12 + i * 16L
      if (readU32(raf, rec) == TAG_NAME.toLong()) {
        nameOffset = readU32(raf, rec + 8)
        nameLength = readU32(raf, rec + 12)
        break
      }
    }
    if (nameOffset < 0 || nameLength <= 0 || nameOffset + nameLength > raf.length()) return null
    val count = readU16(raf, nameOffset + 2)
    val stringOffset = readU16(raf, nameOffset + 4)
    var family1: String? = null
    var family16: String? = null
    var family1Fallback: String? = null
    for (i in 0 until count) {
      val rec = nameOffset + 6 + i * 12L
      val platformId = readU16(raf, rec)
      val encodingId = readU16(raf, rec + 2)
      val languageId = readU16(raf, rec + 4)
      val nameId = readU16(raf, rec + 6)
      if (nameId != 1 && nameId != 16) continue
      val len = readU16(raf, rec + 8)
      val off = readU16(raf, rec + 10)
      val start = nameOffset + stringOffset + off
      if (len <= 0 || start + len > raf.length()) continue
      val bytes = ByteArray(len)
      raf.seek(start)
      raf.readFully(bytes)
      val text = decode(bytes, platformId, encodingId)?.trim()
      if (text.isNullOrEmpty()) continue
      val english = platformId == 3 && (languageId == 0x0409 || languageId == 0)
      when (nameId) {
        16 -> if (family16 == null || english) family16 = text
        1 -> {
          if (english) family1 = text
          if (family1Fallback == null) family1Fallback = text
        }
      }
      if (family16 != null && english) break
    }
    return family16 ?: family1 ?: family1Fallback
  }

  private fun decode(bytes: ByteArray, platformId: Int, encodingId: Int): String? {
    return try {
      when (platformId) {
        // Unicode / Windows：UTF-16BE
        0, 3 -> String(bytes, Charset.forName("UTF-16BE"))
        // Macintosh Roman
        1 -> if (encodingId == 0) String(bytes, Charset.forName("x-MacRoman")) else null
        else -> null
      }
    } catch (_: Throwable) {
      try {
        String(bytes, Charsets.ISO_8859_1)
      } catch (_: Throwable) {
        null
      }
    }
  }

  private fun readU16(raf: RandomAccessFile, pos: Long): Int {
    raf.seek(pos)
    return raf.readUnsignedShort()
  }

  private fun readU32(raf: RandomAccessFile, pos: Long): Long {
    raf.seek(pos)
    return raf.readInt().toLong() and 0xFFFFFFFFL
  }
}
