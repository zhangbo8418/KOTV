package com.bobo.kotv

import android.net.Uri
import android.util.Log
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import com.hierynomus.msdtyp.AccessMask
import com.hierynomus.mssmb2.SMB2CreateDisposition
import com.hierynomus.mssmb2.SMB2ShareAccess
import com.hierynomus.smbj.SMBClient
import com.hierynomus.smbj.auth.AuthenticationContext
import com.hierynomus.smbj.connection.Connection
import com.hierynomus.smbj.session.Session
import com.hierynomus.smbj.share.DiskShare
import com.hierynomus.smbj.share.File as SmbFile
import java.io.IOException
import java.util.EnumSet

/**
 * smb://[domain;]user[:pass]@host[:port]/share/path → Exo DataSource（smbj）。
 * SMB 网盘走 Exo DataSource。
 */
@OptIn(UnstableApi::class)
class KotvSmbDataSource : BaseDataSource(/* isNetwork= */ true) {
  private var client: SMBClient? = null
  private var connection: Connection? = null
  private var session: Session? = null
  private var share: DiskShare? = null
  private var remoteFile: SmbFile? = null
  private var uri: Uri? = null
  private var bytesRemaining: Long = 0
  private var readPosition: Long = 0
  private var opened = false

  @Throws(IOException::class)
  override fun open(dataSpec: DataSpec): Long {
    val u = dataSpec.uri
    if (!isSmbUri(u)) throw IOException("not smb: $u")
    uri = u
    val host = u.host ?: throw IOException("smb host empty")
    val port = if (u.port > 0) u.port else 445
    val userInfo = u.userInfo
    var user = "Guest"
    var pass = ""
    var domain = ""
    if (!userInfo.isNullOrBlank()) {
      val parts = userInfo.split(":", limit = 2)
      user = Uri.decode(parts[0])
      if (parts.size > 1) pass = Uri.decode(parts[1])
      if (user.contains(';')) {
        val du = user.split(';', limit = 2)
        domain = du[0]
        user = du.getOrElse(1) { "Guest" }
      }
    }
    val pathSegs = u.pathSegments
    if (pathSegs.isEmpty()) throw IOException("smb share empty")
    val shareName = pathSegs[0]
    val filePath = pathSegs.drop(1).joinToString("\\")
    try {
      val c = SMBClient()
      client = c
      val conn = c.connect(host, port)
      connection = conn
      val auth =
        if (user.equals("Guest", ignoreCase = true) && pass.isEmpty()) {
          AuthenticationContext.guest()
        } else {
          AuthenticationContext(user, pass.toCharArray(), domain)
        }
      val sess = conn.authenticate(auth)
      session = sess
      val disk = sess.connectShare(shareName) as DiskShare
      share = disk
      val file =
        disk.openFile(
          filePath,
          EnumSet.of(AccessMask.FILE_READ_DATA, AccessMask.FILE_READ_ATTRIBUTES),
          null,
          SMB2ShareAccess.ALL,
          SMB2CreateDisposition.FILE_OPEN,
          null,
        )
      remoteFile = file
      val total = file.getFileInformation().standardInformation.endOfFile
      val position = dataSpec.position.coerceAtLeast(0L)
      if (position > total) throw IOException("smb position beyond EOF")
      readPosition = position
      bytesRemaining =
        if (dataSpec.length != C.LENGTH_UNSET.toLong()) {
          dataSpec.length
        } else {
          (total - position).coerceAtLeast(0L)
        }
      opened = true
      transferStarted(dataSpec)
      return bytesRemaining
    } catch (t: Throwable) {
      closeQuietly()
      throw IOException("smb open failed: ${t.message}", t)
    }
  }

  @Throws(IOException::class)
  override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
    if (length == 0) return 0
    if (bytesRemaining == 0L) return C.RESULT_END_OF_INPUT
    val file = remoteFile ?: return C.RESULT_END_OF_INPUT
    val toRead =
      if (bytesRemaining == C.LENGTH_UNSET.toLong()) {
        length
      } else {
        minOf(length.toLong(), bytesRemaining).toInt()
      }
    val read = file.read(buffer, readPosition, offset, toRead)
    if (read <= 0) return C.RESULT_END_OF_INPUT
    readPosition += read
    if (bytesRemaining != C.LENGTH_UNSET.toLong()) {
      bytesRemaining -= read.toLong()
    }
    bytesTransferred(read)
    return read
  }

  override fun getUri(): Uri? = uri

  @Throws(IOException::class)
  override fun close() {
    if (opened) {
      opened = false
      transferEnded()
    }
    closeQuietly()
  }

  private fun closeQuietly() {
    try {
      remoteFile?.close()
    } catch (_: Throwable) {
    }
    remoteFile = null
    try {
      share?.close()
    } catch (_: Throwable) {
    }
    share = null
    try {
      session?.close()
    } catch (_: Throwable) {
    }
    session = null
    try {
      connection?.close()
    } catch (_: Throwable) {
    }
    connection = null
    try {
      client?.close()
    } catch (_: Throwable) {
    }
    client = null
    uri = null
  }

  class Factory : DataSource.Factory {
    private var listener: TransferListener? = null

    fun setTransferListener(l: TransferListener?): Factory {
      listener = l
      return this
    }

    override fun createDataSource(): DataSource {
      val ds = KotvSmbDataSource()
      listener?.let { ds.addTransferListener(it) }
      return ds
    }
  }

  companion object {
    fun isSmbUri(uri: Uri?): Boolean {
      val scheme = uri?.scheme?.lowercase() ?: return false
      return scheme == "smb"
    }

    fun isSmbUrl(url: String): Boolean = url.trim().lowercase().startsWith("smb://")
  }
}

/** 按 URI scheme 选择 SMB / 上游 DataSource。 */
@OptIn(UnstableApi::class)
class KotvSchemeDataSourceFactory(
  private val defaultFactory: DataSource.Factory,
  private val smbFactory: DataSource.Factory = KotvSmbDataSource.Factory(),
) : DataSource.Factory {
  override fun createDataSource(): DataSource = KotvSchemeDataSource(defaultFactory, smbFactory)
}

@OptIn(UnstableApi::class)
private class KotvSchemeDataSource(
  private val defaultFactory: DataSource.Factory,
  private val smbFactory: DataSource.Factory,
) : DataSource {
  private var active: DataSource? = null
  private val listeners = ArrayList<TransferListener>()

  override fun addTransferListener(transferListener: TransferListener) {
    listeners.add(transferListener)
    active?.addTransferListener(transferListener)
  }

  @Throws(IOException::class)
  override fun open(dataSpec: DataSpec): Long {
    close()
    val ds =
      if (KotvSmbDataSource.isSmbUri(dataSpec.uri)) {
        smbFactory.createDataSource()
      } else {
        defaultFactory.createDataSource()
      }
    for (l in listeners) {
      try {
        ds.addTransferListener(l)
      } catch (_: Throwable) {
      }
    }
    active = ds
    return ds.open(dataSpec)
  }

  @Throws(IOException::class)
  override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
    return active?.read(buffer, offset, length) ?: C.RESULT_END_OF_INPUT
  }

  override fun getUri(): Uri? = active?.uri

  @Throws(IOException::class)
  override fun close() {
    try {
      active?.close()
    } catch (t: Throwable) {
      Log.w("KotvSmb", "close", t)
    }
    active = null
  }
}
