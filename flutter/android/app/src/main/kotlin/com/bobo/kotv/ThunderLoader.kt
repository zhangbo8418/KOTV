package com.bobo.kotv

import android.net.Uri
import android.os.SystemClock
import android.util.Log
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
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import java.util.regex.Pattern

/**
 * 安卓迅雷：对齐 TV Thunder（magnet / thunder / ed2k / torrent / ftp 等），不走 anacrolix。
 *
 * TV 安全点：
 * - Init 在 Application.attachBaseContext 已 set
 * - 首次 parse/fetch 才 XLTaskHelper.get() → loadLibrary（不预热）
 * - clear/stop 只 deleteTask + release，**不** Path.clear 整目录（易与 native 抢文件闪退）
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
  private const val TAG = "KotvThunder"
  private val matchPat = Pattern.compile("(magnet|thunder|ed2k):.*", Pattern.CASE_INSENSITIVE)

  private val currentTask = AtomicReference<GetTaskId?>(null)
  private val currentIndex = AtomicReference(-1)
  private val lastError = AtomicReference("")
  private val nativeBroken = AtomicBoolean(false)

  private val classAvailable: Boolean by lazy {
    try {
      Class.forName("com.xunlei.downloadlib.XLTaskHelper")
      true
    } catch (_: Throwable) {
      false
    }
  }

  fun create(): ThunderLoader = if (classAvailable) ThunderXunleiLoader else ThunderStubLoader

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

  /** 对齐 TV：首次调用才触达 native；失败后永久 stub，避免反复 UnsatisfiedLinkError 崩进程。 */
  private fun xl(): XLTaskHelper {
    if (nativeBroken.get()) throw IllegalStateException("thunder native unavailable")
    if (Init.context() == null) throw IllegalStateException("Init.context null")
    return try {
      XLTaskHelper.get()
    } catch (t: Throwable) {
      if (isNativeLoadFailure(t)) {
        nativeBroken.set(true)
        Log.e(TAG, "thunder native broken", t)
      }
      throw t
    }
  }

  private fun isNativeLoadFailure(t: Throwable): Boolean {
    var c: Throwable? = t
    while (c != null) {
      if (c is UnsatisfiedLinkError || c is LinkageError) return true
      val m = c.message.orEmpty()
      if (m.contains("dlopen", ignoreCase = true) ||
        m.contains("library", ignoreCase = true) && m.contains("find", ignoreCase = true)
      ) {
        return true
      }
      c = c.cause
    }
    return false
  }

  override fun parse(url: String): JSONObject {
    if (!classAvailable || nativeBroken.get()) return ThunderStubLoader.parse(url)
    return try {
      val raw = url.trim()
      if (raw.isEmpty() || (!matchPat.matcher(raw).find() && !isTorrent(raw))) {
        return JSONObject().put("ok", false).put("error", "unsupported url")
      }
      val torrent = isTorrent(raw)
      val dir = Path.thunder(md5(raw))
      val taskId = xl().parse(raw, dir)
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
        val medias = xl().getTorrentInfo(taskId.saveFile).medias
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
        try {
          xl().stopTask(taskId)
        } catch (_: Throwable) {
        }
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
      if (xl().getTaskInfo(taskId).taskStatus == 2) return
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
    if (!classAvailable || nativeBroken.get()) return ThunderStubLoader.fetch(url)
    return try {
      var raw = url.trim()
      lastError.set("")
      // thunder:// 先经 SDK 解码（与 parse 一致），得到 ed2k/magnet/ftp/http…
      if (raw.startsWith("thunder://", ignoreCase = true)) {
        val dir = Path.thunder(md5(raw))
        val decoded = xl().parse(raw, dir).realUrl?.trim().orEmpty()
        if (decoded.isNotEmpty()) raw = decoded
      }
      val playUrl = if (raw.startsWith("magnet", ignoreCase = true)) {
        if (raw.startsWith("magnet://") && raw.contains("?")) {
          addTorrentTask(Uri.parse(raw))
        } else {
          // magnet:?xt=… 未展开：parse 后播第一个媒体
          val parsed = parse(raw)
          if (!parsed.optBoolean("ok", false)) {
            return parsed
          }
          val files = parsed.optJSONArray("files")
          val first = files?.optJSONObject(0)
          val firstPlay = first?.optString("playUrl").orEmpty()
          if (firstPlay.startsWith("magnet://")) {
            addTorrentTask(Uri.parse(firstPlay))
          } else {
            addThunderTask(firstPlay.ifBlank { raw })
          }
        }
      } else {
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
    val name = uri.getQueryParameter("name") ?: torrent.name
    val index = uri.getQueryParameter("index")?.toIntOrNull() ?: 0
    val taskId = xl().addTorrentTask(torrent, parent, index)
    currentTask.set(taskId)
    currentIndex.set(index)
    for (i in 0 until 100) {
      val info: XLTaskInfo = xl().getBtSubTaskInfo(taskId, index).mTaskInfo
        ?: throw IllegalStateException("bt subtask null")
      if (info.mTaskStatus == 3) {
        throw IllegalStateException(info.errorMsg ?: "迅雷错误")
      }
      if (info.mTaskStatus != 0) {
        return xl().getLocalUrl(File(parent, name))
      }
      SystemClock.sleep(100)
    }
    return xl().getLocalUrl(File(parent, name))
  }

  private fun addThunderTask(url: String): String {
    val folder = Path.thunder(md5(url))
    val taskId = xl().addThunderTask(url, folder)
    currentTask.set(taskId)
    currentIndex.set(-1)
    return xl().getLocalUrl(taskId.saveFile)
  }

  override fun progress(): JSONObject {
    if (!classAvailable || nativeBroken.get()) return ThunderStubLoader.progress()
    val task = currentTask.get()
    if (task == null) {
      return ThunderStubLoader.progress()
    }
    return try {
      val idx = currentIndex.get()
      val info: XLTaskInfo = if (idx >= 0) {
        val detail = xl().getBtSubTaskInfo(task, idx)
        detail.mTaskInfo ?: xl().getTaskInfo(task)
      } else {
        xl().getTaskInfo(task)
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
        "error" -> info.errorMsg ?: lastError.get().ifBlank { "迅雷错误" }
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
    if (!classAvailable || nativeBroken.get()) return ThunderStubLoader.clear()
    return try {
      // 对齐 TV Thunder.stop/exit：只停任务 + release，不删整棵 thunder 目录
      val task = currentTask.getAndSet(null)
      currentIndex.set(-1)
      lastError.set("")
      val helper = try {
        xl()
      } catch (_: Throwable) {
        null
      }
      if (helper != null && task != null) {
        try {
          helper.deleteTask(task)
        } catch (t: Throwable) {
          Log.w(TAG, "deleteTask", t)
        }
      }
      if (helper != null) {
        try {
          helper.release()
        } catch (t: Throwable) {
          Log.w(TAG, "release", t)
        }
      }
      JSONObject().put("ok", true).put("cleared", true)
    } catch (t: Throwable) {
      JSONObject().put("ok", false).put("error", t.message ?: t.toString())
    }
  }
}

object ThunderBridge {
  @Volatile
  private var loader: ThunderLoader = ThunderStubLoader

  /** 只注入 Init + 选择 loader；不触达 XLTaskHelper（对齐 TV 懒加载）。 */
  fun start(context: android.content.Context) {
    Init.set(context)
    if (Init.context() == null) {
      throw IllegalStateException("Init.context is null after Init.set")
    }
    loader = ThunderXunleiLoader.create()
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

  fun progress(): JSONObject = try {
    loader.progress()
  } catch (t: Throwable) {
    ThunderStubLoader.progress().put("message", t.message ?: "迅雷进度")
  }

  fun clear(): JSONObject = try {
    loader.clear()
  } catch (t: Throwable) {
    JSONObject().put("ok", false).put("error", t.message ?: t.toString())
  }
}
