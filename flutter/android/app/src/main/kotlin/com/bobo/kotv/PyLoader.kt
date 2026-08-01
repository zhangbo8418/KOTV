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

  fun isStarted(): Boolean = Python.isStarted()

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
    // 勿用空 dict 作 exec globals：部分 spider 依赖 __builtins__/包导入路径。
    val wrapper = """
import io, sys, os, traceback

__old_argv = sys.argv
__old_stdin = sys.stdin
__old_stdout = sys.stdout
__old_stderr = sys.stderr
__err = ""

sys.argv = ["pyrunner.py", __script_path, __key, __ext, __api, __cache_root]
sys.stdin = io.StringIO(__stdin_line + "\n")
sys.stdout = io.StringIO()
sys.stderr = io.StringIO()

os.environ["KOTV_PROXY_PORT"] = str(__proxy_port)
for p in (os.path.dirname(__runner_path), os.path.dirname(__script_path), __cache_root):
    if p and p not in sys.path:
        sys.path.insert(0, p)

code = open(__runner_path, "r", encoding="utf-8", errors="ignore").read()
g = {"__name__": "__main__", "__file__": __runner_path, "__builtins__": __builtins__}
try:
    exec(compile(code, __runner_path, "exec"), g)
except Exception:
    __err = traceback.format_exc()
finally:
    __out = sys.stdout.getvalue()
    if not __err:
        __err = sys.stderr.getvalue()
    sys.argv = __old_argv
    sys.stdin = __old_stdin
    sys.stdout = __old_stdout
    sys.stderr = __old_stderr
""".trimIndent()

    // builtins.exec(code, globals)：globals 必须是 dict，不能传 module
    val globals = main.get("__dict__")
    py.builtins.callAttr("exec", wrapper, globals)
    val err = try {
      main.get("__err")?.toString()?.trim().orEmpty()
    } catch (_: Throwable) {
      ""
    }
    val out = try {
      main.get("__out").toString().trim()
    } catch (_: Throwable) {
      ""
    }
    if (err.isNotEmpty() && out.lines().none { it.trim().startsWith("{") }) {
      throw RuntimeException(err.take(2000))
    }
    val firstLine = out.lines().firstOrNull { it.trim().startsWith("{") }.orEmpty()
    if (firstLine.isEmpty()) {
      if (out.isNotEmpty()) return out
      throw RuntimeException(if (err.isNotEmpty()) err.take(2000) else "python produced no output")
    }

    val resp = JSONObject(firstLine)
    if (!resp.optBoolean("ok", false)) {
      throw RuntimeException(resp.optString("error", "python call failed"))
    }

    if (!resp.has("result") || resp.isNull("result")) return ""
    val result = resp.get("result")
    // 保持 JSON 文本：Go 侧按字符串解析 list/class 等字段
    return when (result) {
      is JSONObject, is org.json.JSONArray -> result.toString()
      else -> result.toString()
    }
  }

  private fun ensurePythonStarted(): Python {
    if (!Python.isStarted()) {
      throw IllegalStateException("Chaquopy not started. Call startSpiderService first.")
    }
    return Python.getInstance()
  }
}
