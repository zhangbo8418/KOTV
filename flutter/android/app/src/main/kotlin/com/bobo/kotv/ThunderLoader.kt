package com.bobo.kotv

import android.net.Uri
import android.os.SystemClock
import com.github.catvod.Init
import com.github.catvod.utils.Path
import com.xunlei.downloadlib.XLTaskHelper
import com.xunlei.downloadlib.parameter.GetTaskId
import com.xunlei.downloadlib.parameter.TorrentFileInfo
import com.xunlei.downloadlib.parameter.XLTaskInfo
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicReference
import java.util.regex.Pattern

/**
 * 安卓迅雷：对齐 TV Thunder（magnet / thunder / ed2k / torrent / ftp 等），不走 anacrolix。
 */
interface ThunderLoader {
  fun parse(url: String): JSONObject
  fun fetch(url: String): JSONObject
  fun progress(): JSONObject
  fun clear(): JSONObject
}

object ThunderStubLoader : ThunderLoader {
  override fun parse(url: String): JSONObject =
    JSONObject().put("ok", false).put("error", "no thunder sdk")

  override fun fetch(url: String): JSONObject =
    JSONObject().put("ok", false).put("error", "no thunder sdk")

  override fun progress(): JSONObject =
    JSONObject()
      .put("ok", true)
      .put("phase", "idle")
      .put("peers", 0)
      .put("bytes", 0)
      .put("need", 0)
      .put("message", "")

  override fun clear(): JSONObject =
    JSONObject().put("ok", true).put("cleared", false)
}

object ThunderXunleiLoader : ThunderLoader {
  private val matchPat = Pattern.compile("(magnet|thunder|ed2k):.*", Pattern.CASE_INSENSITIVE)

  private val currentTask = AtomicReference<GetTaskId?>(null)
  private val currentIndex = AtomicReference(-1)
  private val lastError = AtomicReference("")

  private val sdkAvailable: Boolean by lazy {
    try {
      Class.forName("com.xunlei.downloadlib.XLTaskHelper")
      true
    } catch (_: Throwable) {
      false
    }
  }

  fun create(): ThunderLoader = if (sdkAvailable) ThunderXunleiLoader else ThunderStubLoader

  private fun md5(src: String): String {
    val dig = MessageDigest.getInstance("MD5").digest(src.toByteArray(Charsets.UTF_8))
    return dig.joinToString("") { "%02x".format(it) }
  }

  private fun isTorrent(url: String): Boolean {
    if (url.startsWith("magnet", ignoreCase = true)) return false
    return url.split(";")[0].lowercase().endsWith(".torrent")
  }

  private fun formatSize(size: Long): String {
    if (size <= 0) return ""
    val units = arrayOf("B", "KB", "MB", "GB", "TB")
    var s = size.toDouble()
    var i = 0
    while (s >= 1024 && i < units.lastIndex) {
      s /= 1024
      i++
    }
    return String.format("[%.1f%s]", s, units[i])
  }

  override fun parse(url: String): JSONObject {
    if (!sdkAvailable) return ThunderStubLoader.parse(url)
    return try {
      val raw = url.trim()
      if (raw.isEmpty() || (!matchPat.matcher(raw).find() && !isTorrent(raw))) {
        return JSONObject().put("ok", false).put("error", "unsupported url")
      }
      val torrent = isTorrent(raw)
      val dir = Path.thunder(md5(raw))
      val taskId = XLTaskHelper.get().parse(raw, dir)
      // 对齐 TV：非种子且解码后不是 magnet → 单集直链（ed2k / thunder 解码后的 http/ftp/ed2k 等）
      val real = taskId.realUrl?.trim().orEmpty()
      if (!torrent && !real.startsWith("magnet")) {
        val play = real.ifBlank { raw }
        val files = JSONArray().put(
          JSONObject()
            .put("name", taskId.fileName.ifBlank { play.substringAfterLast('/').ifBlank { "迅雷下载" } })
            .put("index", 0)
            .put("size", 0)
            .put("playUrl", play),
        )
        return JSONObject().put("ok", true).put("files", files)
      }
      if (!torrent) waitMetaDone(taskId)
      try {
        val medias = XLTaskHelper.get().getTorrentInfo(taskId.saveFile).medias
        val files = JSONArray()
        for (info in medias) {
          files.put(fileJson(info))
        }
        if (files.length() == 0) {
          JSONObject().put("ok", false).put("error", "未找到可播媒体文件")
        } else {
          JSONObject().put("ok", true).put("files", files)
        }
      } finally {
        XLTaskHelper.get().stopTask(taskId)
      }
    } catch (t: Throwable) {
      JSONObject().put("ok", false).put("error", t.message ?: t.toString())
    }
  }

  private fun fileJson(info: TorrentFileInfo): JSONObject {
    val name = formatSize(info.fileSize) + info.fileName
    return JSONObject()
      .put("name", name)
      .put("index", info.mFileIndex)
      .put("size", info.fileSize)
      .put("playUrl", info.playUrl)
  }

  private fun waitMetaDone(taskId: GetTaskId) {
    for (i in 0 until 100) {
      if (XLTaskHelper.get().getTaskInfo(taskId).taskStatus == 2) return
      SystemClock.sleep(100)
    }
  }

  /**
   * 对齐 TV Thunder.fetch：
   * - magnet://path?name&index → BT 子任务边下边播
   * - magnet:? / .torrent → 先 parse 再播
   * - ed2k / thunder（解码后）/ ftp 等 → addThunderTask
   */
  override fun fetch(url: String): JSONObject {
    if (!sdkAvailable) return ThunderStubLoader.fetch(url)
    return try {
      var raw = url.trim()
      lastError.set("")
      // thunder:// 先经 SDK 解码（与 parse 一致），得到 ed2k/magnet/ftp/http…
      if (raw.startsWith("thunder://", ignoreCase = true)) {
        val dir = Path.thunder(md5(raw))
        val decoded = XLTaskHelper.get().parse(raw, dir).realUrl?.trim().orEmpty()
        if (decoded.isNotEmpty()) raw = decoded
      }
      val playUrl = if (raw.startsWith("magnet", ignoreCase = true)) {
        if (raw.startsWith("magnet://") && raw.contains("?")) {
          addTorrentTask(Uri.parse(raw))
        } else {
          // magnet:?xt=… 未展开：parse 后播第一个媒体
          val parsed = parse(raw)
          if (!parsed.optBoolean("ok")) {
            throw IllegalStateException(parsed.optString("error", "迅雷解析失败"))
          }
          val files = parsed.optJSONArray("files")
            ?: throw IllegalStateException("迅雷无媒体文件")
          if (files.length() == 0) throw IllegalStateException("迅雷无媒体文件")
          val firstPlay = files.getJSONObject(0).optString("playUrl", "")
          if (firstPlay.startsWith("magnet://")) {
            addTorrentTask(Uri.parse(firstPlay))
          } else {
            addThunderTask(firstPlay.ifBlank { raw })
          }
        }
      } else {
        // ed2k / ftp / http(迅雷链解码) / 其它直链
        addThunderTask(raw)
      }
      JSONObject().put("ok", true).put("url", playUrl)
    } catch (t: Throwable) {
      lastError.set(t.message ?: t.toString())
      JSONObject().put("ok", false).put("error", t.message ?: t.toString())
    }
  }

  private fun addTorrentTask(uri: Uri): String {
    val path = uri.path ?: throw IllegalArgumentException("invalid magnet path")
    val torrent = File(path)
    val parent = torrent.parentFile ?: throw IllegalArgumentException("invalid torrent parent")
    val name = uri.getQueryParameter("name") ?: throw IllegalArgumentException("missing name")
    val index = uri.getQueryParameter("index")?.toIntOrNull()
      ?: throw IllegalArgumentException("missing index")
    val taskId = XLTaskHelper.get().addTorrentTask(torrent, parent, index)
    currentTask.set(taskId)
    currentIndex.set(index)
    for (i in 0 until 100) {
      val info: XLTaskInfo = XLTaskHelper.get().getBtSubTaskInfo(taskId, index).mTaskInfo
      if (info.mTaskStatus == 3) {
        throw IllegalStateException(info.errorMsg ?: "迅雷任务失败")
      }
      if (info.mTaskStatus != 0) {
        return XLTaskHelper.get().getLocalUrl(File(parent, name))
      }
      SystemClock.sleep(100)
    }
    throw IllegalStateException("磁力起播超时")
  }

  private fun addThunderTask(url: String): String {
    val folder = Path.thunder(md5(url))
    val taskId = XLTaskHelper.get().addThunderTask(url, folder)
    currentTask.set(taskId)
    currentIndex.set(0)
    return XLTaskHelper.get().getLocalUrl(taskId.saveFile)
  }

  override fun progress(): JSONObject {
    if (!sdkAvailable) return ThunderStubLoader.progress()
    val task = currentTask.get()
    if (task == null) {
      val err = lastError.get()
      if (err.isNotEmpty()) {
        return JSONObject()
          .put("ok", true)
          .put("phase", "error")
          .put("peers", 0)
          .put("bytes", 0)
          .put("need", 0)
          .put("message", err)
      }
      return ThunderStubLoader.progress()
    }
    return try {
      val idx = currentIndex.get()
      val info: XLTaskInfo = if (idx >= 0) {
        val detail = XLTaskHelper.get().getBtSubTaskInfo(task, idx)
        detail.mTaskInfo ?: XLTaskHelper.get().getTaskInfo(task)
      } else {
        XLTaskHelper.get().getTaskInfo(task)
      }
      val status = info.mTaskStatus
      val bytes = info.mDownloadSize
      val need = info.mFileSize
      val phase = when (status) {
        3 -> "error"
        0 -> "buffer"
        else -> if (bytes > 0) "ready" else "buffer"
      }
      val msg = when (phase) {
        "error" -> info.errorMsg ?: "迅雷错误"
        "ready" -> "迅雷播放中"
        else -> "迅雷缓冲中…"
      }
      JSONObject()
        .put("ok", true)
        .put("phase", phase)
        .put("peers", 0)
        .put("bytes", bytes)
        .put("need", need)
        .put("message", msg)
    } catch (t: Throwable) {
      JSONObject()
        .put("ok", true)
        .put("phase", "buffer")
        .put("peers", 0)
        .put("bytes", 0)
        .put("need", 0)
        .put("message", t.message ?: "迅雷进度")
    }
  }

  override fun clear(): JSONObject {
    if (!sdkAvailable) return ThunderStubLoader.clear()
    return try {
      val task = currentTask.getAndSet(null)
      currentIndex.set(-1)
      lastError.set("")
      if (task != null) {
        XLTaskHelper.get().deleteTask(task)
      }
      XLTaskHelper.get().release()
      Path.clear(Path.thunder())
      Path.thunder()
      JSONObject().put("ok", true).put("cleared", true)
    } catch (t: Throwable) {
      JSONObject().put("ok", false).put("error", t.message ?: t.toString())
    }
  }
}

object ThunderBridge {
  @Volatile
  private var loader: ThunderLoader = ThunderStubLoader

  fun start(context: android.content.Context) {
    Init.set(context)
    if (Init.context() == null) {
      throw IllegalStateException("Init.context is null after Init.set")
    }
    loader = ThunderXunleiLoader.create()
    Path.thunder()
  }

  fun parse(body: JSONObject): JSONObject {
    return try {
      val url = body.optString("url", "").trim()
      if (url.isEmpty()) return JSONObject().put("ok", false).put("error", "empty url")
      if (Init.context() == null) {
        return JSONObject().put("ok", false).put("error", "Init.context null; call ThunderBridge.start first")
      }
      loader.parse(url)
    } catch (t: Throwable) {
      JSONObject().put("ok", false).put("error", t.message ?: t.toString())
    }
  }

  fun fetch(body: JSONObject): JSONObject {
    return try {
      val url = body.optString("url", "").trim()
      if (url.isEmpty()) return JSONObject().put("ok", false).put("error", "empty url")
      if (Init.context() == null) {
        return JSONObject().put("ok", false).put("error", "Init.context null; call ThunderBridge.start first")
      }
      loader.fetch(url)
    } catch (t: Throwable) {
      JSONObject().put("ok", false).put("error", t.message ?: t.toString())
    }
  }

  fun progress(): JSONObject = loader.progress()

  fun clear(): JSONObject = loader.clear()
}
