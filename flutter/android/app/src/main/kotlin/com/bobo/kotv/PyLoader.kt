package com.bobo.kotv

import android.content.Context
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import org.json.JSONObject

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

    val id = 1
    val stdinLine = JSONObject()
      .put("id", id)
      .put("method", method)
      .put("args", argsObj)
      .toString()

    val py = ensurePythonStarted()
    val main = py.getModule("__main__")

    // Chaquopy 17：用 put(Object) 而非已收紧签名的 set(PyObject)
    main.put("__runner_path", runnerPath)
    main.put("__script_path", scriptPath)
    main.put("__key", key)
    main.put("__ext", ext)
    main.put("__api", api)
    main.put("__cache_root", cacheRoot)
    main.put("__stdin_line", stdinLine)
    main.put("__proxy_port", proxyPort)

    // 重要：pyrunner.py 里最后是 for line in sys.stdin: ...，因此我们让 stdin 在一行后 EOF。
    val wrapper = """
import io, sys, os

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
    sys.argv = __old_argv
    sys.stdin = __old_stdin
    sys.stdout = __old_stdout
""".trimIndent()

    // Chaquopy 17：PyObject 无 exec()，走 builtins.exec(code, globals)
    py.builtins.callAttr("exec", wrapper, main)
    val out = main.get("__out").toString().trim()
    val firstLine = out.lines().firstOrNull { it.trim().startsWith("{") }.orEmpty()
    if (firstLine.isEmpty()) {
      return out
    }

    val resp = JSONObject(firstLine)
    if (!resp.optBoolean("ok", false)) {
      throw RuntimeException(resp.optString("error", "python call failed"))
    }

    val result = resp.get("result")
    return if (result == JSONObject.NULL) "" else result.toString()
  }

  private fun ensurePythonStarted(): Python {
    if (!Python.isStarted()) {
      throw IllegalStateException("Chaquopy not started. Call startSpiderService first.")
    }
    return Python.getInstance()
  }
}
