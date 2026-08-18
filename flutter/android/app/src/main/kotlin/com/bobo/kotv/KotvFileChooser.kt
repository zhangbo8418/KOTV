package com.bobo.kotv

import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.util.Log
import com.github.catvod.utils.Path
import java.io.File
import java.net.URLDecoder
import java.nio.charset.StandardCharsets

/**
 * 对齐 TV [com.fongmi.android.tv.utils.FileChooser]：
 * 把 SAF Document URI 解析成磁盘真实路径，避免只拷单个 JSON 到 cache/UUID。
 *
 * 注意：Downloads 文档提供者常只给 DISPLAY_NAME；若直接拼 `/Download/文件名`
 * 会丢掉子目录（如 `Download/py/api.json` → 误成 `Download/api.json`）。
 */
object KotvFileChooser {
  private const val TAG = "KotvFileChooser"

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
    // 尽量打开系统文件管理「内部存储」视图，拿到 primary:Download/py/… 完整相对路径
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      try {
        val dl = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        intent.putExtra(
          DocumentsContract.EXTRA_INITIAL_URI,
          Uri.parse("content://com.android.externalstorage.documents/document/primary:${Uri.encode("Download")}"),
        )
        if (!dl.exists()) {
          // ignore
        }
      } catch (_: Throwable) {
      }
    }
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
    } catch (t: Throwable) {
      Log.w(TAG, "getPathFromUri primary failed: $uri", t)
      path = null
    }
    path = decodePath(path)
    if (path != null && File(path).exists()) {
      return path
    }
    // Downloads 文档常丢子目录：用显示名在 Download 下递归找
    val name = getNameColumn(context, uri)
    if (!name.isNullOrBlank()) {
      val found = findUnderDownloads(name)
      if (found != null) return found
    }
    if (path != null && File(path).exists()) return path
    return createFileFromUri(context, uri)
  }

  private fun decodePath(path: String?): String? {
    if (path.isNullOrBlank()) return null
    return try {
      URLDecoder.decode(path, StandardCharsets.UTF_8.name())
    } catch (_: Throwable) {
      path
    }
  }

  private fun getPathFromDocumentUri(context: Context, uri: Uri): String? {
    val docId = DocumentsContract.getDocumentId(uri) ?: return null
    val split = docId.split(":".toRegex()).dropLastWhile { it.isEmpty() }.toTypedArray()
    return when {
      isExternalStorageDocument(uri) -> getExternalPath(docId, split)
      isDownloadsDocument(uri) -> getDownloadsPath(context, uri, docId)
      isMediaDocument(uri) -> getMediaPath(context, split)
      else -> getDataColumn(context, uri)
    }
  }

  private fun getExternalPath(docId: String, split: Array<String>): String {
    return if (split.isNotEmpty() && "primary".equals(split[0], true)) {
      if (split.size > 1) {
        // primary:Download/py/api.json → /storage/emulated/0/Download/py/api.json
        Environment.getExternalStorageDirectory().toString() + "/" + split[1]
      } else {
        Environment.getExternalStorageDirectory().toString() + "/"
      }
    } else {
      "/storage/" + docId.replace(":", "/")
    }
  }

  private fun getDownloadsPath(context: Context, uri: Uri, docId: String): String? {
    if (docId.startsWith("raw:")) {
      val raw = docId.removePrefix("raw:")
      if (File(raw).exists()) return raw
    }
    // Android 10+：msf: / msd: → MediaStore id
    if (docId.startsWith("msf:") || docId.startsWith("msd:")) {
      val id = docId.substringAfter(':')
      val fromStore = mediaStorePathById(context, id)
      if (fromStore != null) return fromStore
    }
    // 完整 DATA 列（含子目录）
    getDataColumn(context, uri)?.let { if (File(it).exists()) return it }

    // 数字 id → public_downloads
    try {
      val id = docId.toLong()
      getDataColumn(
        context,
        ContentUris.withAppendedId(Uri.parse("content://downloads/public_downloads"), id),
      )?.let { if (File(it).exists()) return it }
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        getDataColumn(
          context,
          ContentUris.withAppendedId(MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL), id),
        )?.let { if (File(it).exists()) return it }
      }
    } catch (_: Throwable) {
    }

    // RELATIVE_PATH + DISPLAY_NAME（保留 Download/py/）
    relativeDownloadPath(context, uri)?.let { if (File(it).exists()) return it }

    val fileName = getNameColumn(context, uri) ?: return null
    // 仅当根目录下确实有该文件才用扁平路径；否则交给上层 findUnderDownloads
    val flat = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), fileName)
    if (flat.isFile) return flat.absolutePath
    return findUnderDownloads(fileName)
  }

  private fun mediaStorePathById(context: Context, id: String): String? {
    val longId = id.toLongOrNull() ?: return null
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      getDataColumn(
        context,
        ContentUris.withAppendedId(MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL), longId),
      )?.let { if (File(it).exists()) return it }
      getDataColumn(
        context,
        ContentUris.withAppendedId(MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL), longId),
      )?.let { if (File(it).exists()) return it }
    }
    getDataColumn(
      context,
      ContentUris.withAppendedId(Uri.parse("content://downloads/public_downloads"), longId),
    )?.let { if (File(it).exists()) return it }
    return null
  }

  private fun relativeDownloadPath(context: Context, uri: Uri): String? {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
    val projection = arrayOf(
      MediaStore.MediaColumns.RELATIVE_PATH,
      MediaStore.MediaColumns.DISPLAY_NAME,
      MediaStore.MediaColumns.DATA,
    )
    return try {
      context.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
        if (!cursor.moveToFirst()) return null
        val dataIdx = cursor.getColumnIndex(MediaStore.MediaColumns.DATA)
        if (dataIdx >= 0) {
          val data = cursor.getString(dataIdx)
          if (!data.isNullOrBlank() && File(data).exists()) return data
        }
        val relIdx = cursor.getColumnIndex(MediaStore.MediaColumns.RELATIVE_PATH)
        val nameIdx = cursor.getColumnIndex(MediaStore.MediaColumns.DISPLAY_NAME)
        if (relIdx < 0 || nameIdx < 0) return null
        val rel = cursor.getString(relIdx)?.trim()?.trimEnd('/') ?: return null
        val name = cursor.getString(nameIdx)?.trim().orEmpty()
        if (name.isEmpty()) return null
        // RELATIVE_PATH 形如 Download/py/ 或 Download/
        val full = File(Environment.getExternalStorageDirectory(), "$rel/$name")
        if (full.exists()) full.absolutePath else null
      }
    } catch (_: Throwable) {
      null
    }
  }

  /** 在 Download 下按文件名递归查找（多匹配时优先路径更深 / 含 json 同级的）。 */
  private fun findUnderDownloads(fileName: String): String? {
    val root = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
    if (!root.isDirectory) return null
    val matches = ArrayList<File>()
    try {
      root.walkTopDown().maxDepth(8).forEach { f ->
        if (f.isFile && f.name == fileName) matches.add(f)
      }
    } catch (t: Throwable) {
      Log.w(TAG, "walk Download failed", t)
    }
    if (matches.isEmpty()) return null
    if (matches.size == 1) return matches[0].absolutePath
    // 多个同名：优先更深路径（子目录里的配置）
    return matches.maxByOrNull { it.absolutePath.length }?.absolutePath
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

  fun storageRoot(): String = Environment.getExternalStorageDirectory().absolutePath

  /**
   * 对齐 TV FileChooser.show：电视 / 无可用文档选择器时走应用内 FileActivity，
   * 才能进目录；系统桩选择器常把目录当文件返回。
   */
  fun shouldUseFileBrowser(context: Context): Boolean {
    val ui = context.resources.configuration.uiMode and Configuration.UI_MODE_TYPE_MASK
    if (ui == Configuration.UI_MODE_TYPE_TELEVISION) return true
    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
    intent.addCategory(Intent.CATEGORY_OPENABLE)
    intent.type = "*/*"
    val infos = context.packageManager.queryIntentActivities(intent, PackageManager.MATCH_DEFAULT_ONLY)
    if (infos.isEmpty()) return true
    val pkg = infos[0].activityInfo?.packageName ?: return true
    return pkg.contains("frameworkpackagestubs")
  }

  fun hasStoragePermission(context: Context): Boolean {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
      return Environment.isExternalStorageManager()
    }
    return context.checkSelfPermission(android.Manifest.permission.READ_EXTERNAL_STORAGE) ==
      PackageManager.PERMISSION_GRANTED
  }
}
