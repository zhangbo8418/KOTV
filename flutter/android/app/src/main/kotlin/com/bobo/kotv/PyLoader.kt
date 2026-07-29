package com.bobo.kotv

import android.content.Context
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import org.json.JSONObject

import java.util.UUID

/**
 * Chaquopy 执行 Python spider runner：
 * 复用 KOTV 自带 `pyrunner.py` 的 stdin/stdout JSON 协议。
 *
 * 设计目标：不改 Go 侧 Python 协议，仅把“进程 IO”替换成“同进程 Python exec + StringIO”。
 */
object PyLoader {

  fun startIfNeeded(context: Context) {
    if (!Python.isStarted()) {
      Python.start(AndroidPlatform(context.applicationContext))
    }
  }

  fun callPython(req: JSONObject): String {
    val runnerPath = req.getString("runnerPath")
    val scriptPath = req.getString("scriptPath")
    val key = req.getString("key")
    val ext = req.optString("ext", "")
    val api = req.getString("api")
    val cacheRoot = req.getString("cacheRoot")
    val proxyPort = req.optInt("proxyPort", 9978)

    val method = req.getString("method")
    val argsObj = req.optJSONObject("args") ?: JSONObject()

    // runner JSON 请求（不追求与 Go 的 reqID 完全一致；只取 result）
    val id = 1
    val stdinLine = JSONObject()
      .put("id", id)
      .put("method", method)
      .put("args", argsObj)
      .toString()

    val py = ensurePythonStarted(req.optString("pythonVersion", ""))

    // 在 __main__ 里执行 runner；用 StringIO 注入 sys.stdin 并抓 sys.stdout。
    val main = py.getModule("__main__")
    val token = UUID.randomUUID().toString()

    main.set("__kotv_token", token)
    main.set("__runner_path", runnerPath)
    main.set("__script_path", scriptPath)
    main.set("__key", key)
    main.set("__ext", ext)
    main.set("__api", api)
    main.set("__cache_root", cacheRoot)
    main.set("__stdin_line", stdinLine)
    main.set("__proxy_port", proxyPort)

    // 重要：pyrunner.py 里最后是 for line in sys.stdin: ...，因此我们让 stdin 在一行后 EOF。
    val wrapper = """
import io, sys, os, traceback

__old_argv = sys.argv
__old_stdin = sys.stdin
__old_stdout = sys.stdout

sys.argv = ["pyrunner.py", __script_path, __key, __ext, __api, __cache_root]
sys.stdin = io.StringIO(__stdin_line + "\n")
sys.stdout = io.StringIO()

os.environ["KOTV_PROXY_PORT"] = str(__proxy_port)

code = open(__runner_path, "r", encoding="utf-8", errors="ignore").read()
try:
    exec(compile(code, __runner_path, "exec"), {})
finally:
    __out = sys.stdout.getvalue()
    # 恢复 sys 对象（尽量减少污染）
    sys.argv = __old_argv
    sys.stdin = __old_stdin
    sys.stdout = __old_stdout
""".trimIndent()

    // 让 wrapper 执行后，把 __out 交回给 Kotlin。
    py.getModule("__main__").exec(wrapper)
    val out = main.get("__out").toString().trim()
    val firstLine = out.lines().firstOrNull { it.trim().startsWith("{") }.orEmpty()
    if (firstLine.isEmpty()) {
      return out
    }

    val resp = JSONObject(firstLine)
    if (!resp.optBoolean("ok", false)) {
      throw RuntimeException(resp.optString("error", "python call failed"))
    }

    // resp.result 在 runner 中可能是 JSON 字符串（dict/list 的 json.dumps 输出）或普通字符串。
    val result = resp.get("result")
    return if (result == JSONObject.NULL) "" else result.toString()
  }

  private fun ensurePythonStarted(_pythonVersion: String): Python {
    // Chaquopy 的 Python 启动与 pip 安装由 Gradle 插件完成；这里只做懒启动。
    if (!Python.isStarted()) {
      throw IllegalStateException("Chaquopy not started. Call startSpiderService first.")
    }
    return Python.getInstance()
  }
}

