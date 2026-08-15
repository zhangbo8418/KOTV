package com.bobo.kotv

import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import com.github.catvod.utils.Path
import java.io.File
import java.net.URLDecoder
import java.nio.charset.StandardCharsets

/**
 * 对齐 TV [com.fongmi.android.tv.utils.FileChooser]：
 * 把 SAF Document URI 解析成磁盘真实路径，避免只拷单个 JSON 到 cache/UUID。
 */
object KotvFileChooser {

  fun openDocumentIntent(): Intent {
    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
    intent.addCategory(Intent.CATEGORY_OPENABLE)
    intent.type = "*/*"
    intent.putExtra(
      Intent.EXTRA_MIME_TYPES,
      arrayOf(
        "application/json",
        "text/plain",
        "text/*",
        "application/octet-stream",
        "*/*",
      ),
    )
    intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, false)
    intent.putExtra("android.content.extra.SHOW_ADVANCED", true)
    return Intent.createChooser(intent, "")
  }

  fun getPathFromUri(context: Context, uri: Uri): String? {
    var path: String? = null
    try {
      if (DocumentsContract.isDocumentUri(context, uri)) {
        path = getPathFromDocumentUri(context, uri)
      } else if (ContentResolver.SCHEME_CONTENT.equals(uri.scheme, true)) {
        path = getDataColumn(context, uri)
      } else if (ContentResolver.SCHEME_FILE.equals(uri.scheme, true)) {
        path = uri.path
      }
    } catch (_: Throwable) {
      path = null
    }
    if (path != null) {
      return try {
        URLDecoder.decode(path, StandardCharsets.UTF_8.name())
      } catch (_: Throwable) {
        path
      }
    }
    return createFileFromUri(context, uri)
  }

  private fun getPathFromDocumentUri(context: Context, uri: Uri): String? {
    val docId = DocumentsContract.getDocumentId(uri) ?: return null
    val split = docId.split(":".toRegex()).dropLastWhile { it.isEmpty() }.toTypedArray()
    return when {
      isExternalStorageDocument(uri) -> getExternalPath(docId, split)
      isDownloadsDocument(uri) -> getDownloadsPath(context, uri, docId)
      isMediaDocument(uri) -> getMediaPath(context, split)
      else -> null
    }
  }

  private fun getExternalPath(docId: String, split: Array<String>): String {
    return if (split.isNotEmpty() && "primary".equals(split[0], true)) {
      if (split.size > 1) {
        Environment.getExternalStorageDirectory().toString() + "/" + split[1]
      } else {
        Environment.getExternalStorageDirectory().toString() + "/"
      }
    } else {
      "/storage/" + docId.replace(":", "/")
    }
  }

  private fun getDownloadsPath(context: Context, uri: Uri, docId: String): String? {
    if (docId.startsWith("raw:")) return docId.removePrefix("raw:")
    val fileName = getNameColumn(context, uri)
    if (fileName != null) {
      return Environment.getExternalStorageDirectory().toString() + "/Download/" + fileName
    }
    return try {
      val id = docId.toLong()
      getDataColumn(
        context,
        ContentUris.withAppendedId(Uri.parse("content://downloads/public_downloads"), id),
      )
    } catch (_: Throwable) {
      null
    }
  }

  private fun getMediaPath(context: Context, split: Array<String>): String? {
    if (split.size < 2) return null
    val contentUri = when (split[0]) {
      "image" -> imageUri()
      "video" -> videoUri()
      "audio" -> audioUri()
      else -> filesUri()
    }
    return try {
      getDataColumn(context, ContentUris.withAppendedId(contentUri, split[1].toLong()))
    } catch (_: Throwable) {
      null
    }
  }

  /** SAF 无法解析真实路径时：仅拷贝单文件（与 TV 相同回退，相对脚本仍可能缺失）。 */
  private fun createFileFromUri(context: Context, uri: Uri): String? {
    val projection = arrayOf(MediaStore.MediaColumns.DISPLAY_NAME)
    return try {
      context.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
        if (!cursor.moveToFirst()) return null
        val name = cursor.getString(cursor.getColumnIndexOrThrow(projection[0])) ?: return null
        val input = context.contentResolver.openInputStream(uri) ?: return null
        val file = Path.cache(name)
        Path.copy(input, file)
        file.absolutePath
      }
    } catch (_: Throwable) {
      null
    }
  }

  private fun getDataColumn(context: Context, uri: Uri?): String? {
    if (uri == null) return null
    val projection = arrayOf(MediaStore.MediaColumns.DATA)
    return try {
      context.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
        if (!cursor.moveToFirst()) return null
        cursor.getString(cursor.getColumnIndexOrThrow(projection[0]))
      }
    } catch (_: Throwable) {
      null
    }
  }

  private fun getNameColumn(context: Context, uri: Uri): String? {
    val projection = arrayOf(MediaStore.MediaColumns.DISPLAY_NAME)
    return try {
      context.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
        if (!cursor.moveToFirst()) return null
        cursor.getString(cursor.getColumnIndexOrThrow(projection[0]))
      }
    } catch (_: Throwable) {
      null
    }
  }

  private fun imageUri(): Uri =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
    } else {
      MediaStore.Images.Media.EXTERNAL_CONTENT_URI
    }

  private fun videoUri(): Uri =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
    } else {
      MediaStore.Video.Media.EXTERNAL_CONTENT_URI
    }

  private fun audioUri(): Uri =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
    } else {
      MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
    }

  private fun filesUri(): Uri =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
    } else {
      MediaStore.Files.getContentUri("external")
    }

  private fun isExternalStorageDocument(uri: Uri): Boolean =
    "com.android.externalstorage.documents" == uri.authority

  private fun isDownloadsDocument(uri: Uri): Boolean =
    "com.android.providers.downloads.documents" == uri.authority

  private fun isMediaDocument(uri: Uri): Boolean =
    "com.android.providers.media.documents" == uri.authority

  fun hasStoragePermission(context: Context): Boolean {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
      return Environment.isExternalStorageManager()
    }
    return context.checkSelfPermission(android.Manifest.permission.READ_EXTERNAL_STORAGE) ==
      PackageManager.PERMISSION_GRANTED
  }
}
