package com.bobo.kotv

import android.content.Context
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import org.json.JSONObject

/**
 * Chaquopy 执行 Python spider。
 *
 * 桌面 pyrunner 常驻，init 后的 host/session 会保留。
 * Android 若每次冷 exec，会出现相对 URL 无 scheme、headers 拼进 URL 等错误。
 * 这里在解释器里缓存 session（按 siteKey），跨 /py/call 复用同一 Spider 实例。
 */
object PyLoader {

  @Volatile
  private var bridgeInstalled = false

  fun isStarted(): Boolean = Python.isStarted()

  fun startIfNeeded(context: Context) {
    if (!Python.isStarted()) {
      Python.start(AndroidPlatform(context.applicationContext))
    }
  }

  fun callPython(req: JSONObject): String {
    val py = ensurePythonStarted()
    ensureBridge(py)

    val main = py.getModule("__main__")
    main.put("__kotv_req", req.toString())

    val runner = """
__kotv_out = kotv_py_dispatch(__kotv_req)
""".trimIndent()

    py.builtins.callAttr("exec", runner, main.get("__dict__"))

    val out = try {
      main.get("__kotv_out")?.toString()?.trim().orEmpty()
    } catch (_: Throwable) {
      ""
    }
    if (out.isEmpty()) {
      throw RuntimeException("python produced no output")
    }

    val resp = JSONObject(out)
    if (!resp.optBoolean("ok", false)) {
      throw RuntimeException(resp.optString("error", "python call failed").take(2000))
    }
    if (!resp.has("result") || resp.isNull("result")) return ""
    val result = resp.get("result")
    return when (result) {
      is JSONObject, is org.json.JSONArray -> result.toString()
      else -> result.toString()
    }
  }

  fun clearSessions() {
    if (!Python.isStarted()) return
    try {
      val py = Python.getInstance()
      ensureBridge(py)
      py.builtins.callAttr("exec", "kotv_py_clear()", py.getModule("__main__").get("__dict__"))
    } catch (_: Throwable) {
    }
  }

  private fun ensureBridge(py: Python) {
    if (bridgeInstalled) return
    synchronized(this) {
      if (bridgeInstalled) return
      val main = py.getModule("__main__")
      val bootstrap = """
import importlib.util, json, os, sys, traceback, types

_KOTV_PY_SESSIONS = {}

def kotv_py_clear():
    _KOTV_PY_SESSIONS.clear()

def _kotv_load_session(runner_path, script_path, key, ext, api, cache_root, proxy_port):
    os.environ["KOTV_PROXY_PORT"] = str(proxy_port)
    os.environ["KOTV_PY_CACHE"] = str(cache_root)
    for p in (os.path.dirname(runner_path), os.path.dirname(script_path), cache_root):
        if p and p not in sys.path:
            sys.path.insert(0, p)

    # 每次加载用唯一模块名，避免换源/改 ext 后命中旧 sys.modules
    safe = "".join(ch if ch.isalnum() else "_" for ch in key)[:40]
    mod_name = "kotv_pyrunner_%s_%d" % (safe, len(_KOTV_PY_SESSIONS) + 1)
    old_argv, old_stdin = sys.argv, sys.stdin
    try:
        sys.argv = ["pyrunner.py", script_path, key, ext, api, cache_root]
        # pyrunner 仅在 __name__ == "__main__" 时跑 repl；spec 加载不会进 REPL
        spec = importlib.util.spec_from_file_location(mod_name, runner_path)
        mod = importlib.util.module_from_spec(spec)
        sys.modules[mod_name] = mod
        spec.loader.exec_module(mod)
    finally:
        sys.argv = old_argv
        sys.stdin = old_stdin

    return {
        "mod": mod,
        "script": script_path,
        "api": api,
        "ext": ext,
        "cache": cache_root,
        "inited": False,
    }

def kotv_py_dispatch(req_json):
    try:
        req = json.loads(req_json)
        runner_path = req["runnerPath"]
        script_path = req["scriptPath"]
        key = req["key"]
        ext = req.get("ext") or ""
        api = req["api"]
        cache_root = req["cacheRoot"]
        proxy_port = int(req.get("proxyPort") or 9978)
        method = req["method"]
        args = req.get("args") or {}

        slot = int(req.get("slot") or 0)
        sess_key = "%s#%d" % (key, slot)

        sess = _KOTV_PY_SESSIONS.get(sess_key)
        if (
            sess is None
            or sess.get("script") != script_path
            or sess.get("api") != api
            or sess.get("ext") != ext
            or sess.get("cache") != cache_root
        ):
            sess = _kotv_load_session(runner_path, script_path, key, ext, api, cache_root, proxy_port)
            _KOTV_PY_SESSIONS[sess_key] = sess

        mod = sess["mod"]
        # 非 init：确保先 init 一次（对齐桌面常驻进程）
        if method != "init" and not sess.get("inited"):
            mod.invoke("init", {"extend": ext})
            sess["inited"] = True
        result = mod.invoke(method, args)
        if method == "init":
            sess["inited"] = True
        return json.dumps({"ok": True, "result": result}, ensure_ascii=False)
    except Exception as exc:
        traceback.print_exc()
        return json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False)
""".trimIndent()
      py.builtins.callAttr("exec", bootstrap, main.get("__dict__"))
      bridgeInstalled = true
    }
  }

  private fun ensurePythonStarted(): Python {
    if (!Python.isStarted()) {
      throw IllegalStateException("Chaquopy not started. Call startSpiderService first.")
    }
    return Python.getInstance()
  }
}
