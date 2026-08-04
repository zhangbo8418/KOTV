# Persistent CatVod Python spider runner for KOTV.
import importlib.util
import json
import os
import re
import ssl
import sys
import traceback


def _prepend_sys_path(*candidates):
    for path in candidates:
        if path and os.path.isdir(path) and path not in sys.path:
            sys.path.insert(0, path)


def _python_home_candidates():
    homes = []
    for key in ("PYTHONHOME", "KOTV_PYTHON_HOME"):
        v = os.environ.get(key, "").strip()
        if v:
            homes.append(v)
    # 进程内 embed：sys.executable 常是 kotv-engine，不能只靠它找 site-packages
    exe = os.path.abspath(getattr(sys, "executable", "") or "")
    if exe:
        exe_dir = os.path.dirname(exe)
        homes.extend([
            exe_dir,
            os.path.dirname(exe_dir),
            os.path.join(os.path.dirname(exe_dir), "python"),
            os.path.join(os.path.dirname(os.path.dirname(exe_dir)), "Resources", "runtime", "python"),
            os.path.join(os.path.dirname(os.path.dirname(exe_dir)), "runtime", "python"),
        ])
    rt = os.environ.get("KOTV_RUNTIME", "").strip()
    if rt:
        homes.append(os.path.join(rt, "python"))
        homes.append(rt)
    # 去重保序
    out, seen = [], set()
    for h in homes:
        h = os.path.abspath(h) if h else ""
        if h and h not in seen:
            seen.add(h)
            out.append(h)
    return out


def _ensure_bundled_site_packages():
    """Windows embed 的 python*._pth 常忽略 PYTHONPATH；显式把 Lib/site-packages 塞进 sys.path。"""
    ver = "python%d.%d" % sys.version_info[:2]
    for home in _python_home_candidates():
        _prepend_sys_path(
            os.path.join(home, "Lib", "site-packages"),
            os.path.join(home, "lib", "site-packages"),
            os.path.join(home, "lib", ver, "site-packages"),
            os.path.join(home, "lib", ver),
            os.path.join(home, "Lib"),
        )
        # 少数布局：python.exe 在 Scripts/ 或 bin/ 下
        parent = os.path.dirname(home)
        _prepend_sys_path(
            os.path.join(parent, "Lib", "site-packages"),
            os.path.join(parent, "lib", "site-packages"),
            os.path.join(parent, "lib", ver, "site-packages"),
        )


_ensure_bundled_site_packages()


def _ensure_ssl_certs():
    """桌面/embed Python 常缺 CA，补齐后让 requests/urlopen 可用 HTTPS。"""
    candidates = []
    try:
        import certifi

        candidates.append(certifi.where())
    except Exception:
        pass

    # Windows embed（PythonVista / PBS）常见 certifi 布局
    exe_dir = os.path.dirname(os.path.abspath(sys.executable))
    for rel in (
        os.path.join(exe_dir, "Lib", "site-packages", "certifi", "cacert.pem"),
        os.path.join(exe_dir, "lib", "site-packages", "certifi", "cacert.pem"),
    ):
        candidates.append(rel)

    candidates.extend([
        os.environ.get("SSL_CERT_FILE", ""),
        os.environ.get("REQUESTS_CA_BUNDLE", ""),
        "/etc/ssl/cert.pem",
        "/etc/ssl/certs/ca-certificates.crt",
        "/etc/pki/tls/certs/ca-bundle.crt",
    ])
    try:
        import glob

        candidates.extend(glob.glob("/opt/homebrew/etc/openssl@*/cert.pem"))
        candidates.extend(glob.glob("/usr/local/etc/openssl@*/cert.pem"))
        candidates.extend(
            glob.glob("/Library/Frameworks/Python.framework/Versions/*/etc/openssl/cert.pem")
        )
    except Exception:
        pass

    cafile = next((p for p in candidates if p and os.path.isfile(p)), None)
    if cafile:
        os.environ.setdefault("SSL_CERT_FILE", cafile)
        os.environ.setdefault("REQUESTS_CA_BUNDLE", cafile)
        os.environ.setdefault("CURL_CA_BUNDLE", cafile)
        try:
            ssl._create_default_https_context = lambda: ssl.create_default_context(cafile=cafile)
        except Exception:
            pass
        return

    # 仍找不到证书时降级，避免部分源整站不可用
    try:
        ssl._create_default_https_context = ssl._create_unverified_context
    except Exception:
        pass


_ensure_ssl_certs()

from urllib.parse import urljoin
from urllib.request import urlopen
import base64

script = os.path.abspath(sys.argv[1])
site_key = sys.argv[2]
ext = sys.argv[3]
api = sys.argv[4]
cache = os.path.abspath(sys.argv[5])

_prepend_sys_path(cache, os.path.dirname(script), os.path.join(cache, "base"))

# 标准库 / 捆绑三方：禁止当依赖从爬虫源目录下载，否则会把 cache 里的假文件盖住真模块。
_STDLIB_TOP = set(getattr(sys, "stdlib_module_names", ())) | {
    "abc", "argparse", "array", "asyncio", "atexit", "base64", "binascii", "bisect",
    "builtins", "bz2", "calendar", "cmath", "codecs", "collections", "concurrent",
    "contextlib", "copy", "csv", "ctypes", "dataclasses", "datetime", "decimal",
    "dis", "email", "encodings", "enum", "errno", "fnmatch", "fractions", "functools",
    "gc", "getopt", "getpass", "gettext", "glob", "gzip", "hashlib", "heapq", "hmac",
    "html", "http", "idlelib", "imaplib", "importlib", "inspect", "io", "ipaddress",
    "itertools", "json", "keyword", "linecache", "locale", "logging", "lzma", "math",
    "mimetypes", "mmap", "multiprocessing", "netrc", "numbers", "operator", "os",
    "pathlib", "pickle", "pkgutil", "platform", "plistlib", "poplib", "posixpath",
    "pprint", "profile", "pstats", "pty", "pwd", "py_compile", "queue", "quopri",
    "random", "re", "reprlib", "secrets", "select", "selectors", "shelve", "shlex",
    "shutil", "signal", "site", "smtplib", "socket", "socketserver", "sqlite3", "ssl",
    "stat", "statistics", "string", "struct", "subprocess", "sys", "sysconfig",
    "tarfile", "tempfile", "textwrap", "threading", "time", "timeit", "token",
    "tokenize", "tomllib", "trace", "traceback", "tracemalloc", "types", "typing",
    "unicodedata", "unittest", "urllib", "uuid", "venv", "warnings", "wave",
    "weakref", "webbrowser", "xml", "xmlrpc", "zipfile", "zipimport", "zlib",
    "_thread", "__future__",
    # 常见捆绑库（不应从爬虫仓下载）
    "requests", "urllib3", "certifi", "charset_normalizer", "idna", "lxml", "bs4",
    "beautifulsoup4", "Crypto", "Cryptodome", "PIL", "numpy", "socks", "websocket",
}


def _is_blocked_dep_name(name):
    base = os.path.basename(str(name)).replace(".py", "").strip()
    if not base:
        return True
    top = base.split(".")[0]
    return top in _STDLIB_TOP


def _local_package_dir(name):
    """cache/<name>/ 已是包（如 TV/Chaquopy 的 base.spider）时返回目录。"""
    top = os.path.basename(str(name)).replace(".py", "").strip().split(".")[0]
    if not top:
        return ""
    pkg = os.path.join(cache, top)
    if not os.path.isdir(pkg):
        return ""
    if os.path.isfile(os.path.join(pkg, "__init__.py")) or os.path.isfile(os.path.join(pkg, "spider.py")):
        return pkg
    return ""


def _looks_like_python_source(data):
    """拒绝把接口错误 JSON 写进 cache（否则会盖住 stdlib，如 concurrent.py）。"""
    if not data:
        return False
    head = data.lstrip()[:800]
    if not head:
        return False
    if head.startswith(b"{") or head.startswith(b"["):
        # 爬虫仓 404/500 常返回 {"code":500,"message":"...","data":null}
        if b'"code"' in head[:400] or b'"message"' in head[:400] or b'"data"' in head[:400]:
            return False
        # 纯 JSON 依赖极少见；宁可跳过也不要毒化 cache
        return False
    return True


def _scrub_poisoned_cache():
    """清掉已写入的假依赖（历史 concurrent.py 等）。"""
    try:
        names = os.listdir(cache)
    except Exception:
        return
    for fn in names:
        if not fn.endswith(".py"):
            continue
        path = os.path.join(cache, fn)
        try:
            with open(path, "rb") as f:
                data = f.read(800)
            # stdlib 同名文件一律删（绝不该在 cache）；其它文件若是错误 JSON 也删
            top = fn[:-3].split(".")[0]
            if top in _STDLIB_TOP or not _looks_like_python_source(data):
                os.remove(path)
                print("[pyrunner] removed poisoned cache file: %s" % fn, file=sys.stderr)
        except Exception:
            pass


_scrub_poisoned_cache()

# 若历史误下了 cache/base.py，会盖住 cache/base/ 包（from base.spider）。
for _shadow in list(os.listdir(cache)) if os.path.isdir(cache) else []:
    if not _shadow.endswith(".py"):
        continue
    _top = _shadow[:-3]
    if _local_package_dir(_top):
        try:
            os.remove(os.path.join(cache, _shadow))
            print("[pyrunner] removed package-shadowing file: %s" % _shadow, file=sys.stderr)
        except Exception:
            pass


def _download_dep(name):
    """从爬虫 api 同目录拉取依赖 py 到 cache（失败忽略，由后续 import 报错）。

    对齐 TV：依赖来自 getDependence()；内置 base.spider 包不从仓拉 base.py。
    """
    name = name if str(name).endswith(".py") else str(name) + ".py"
    if _is_blocked_dep_name(name):
        return
    # TV Chaquopy 自带 base/spider.py；KOTV 写入 cache/base/。勿再拉同名 .py 以免盖包。
    if _local_package_dir(name):
        return
    target = os.path.join(cache, os.path.basename(name))
    if os.path.isfile(target) and os.path.getsize(target) > 0:
        try:
            with open(target, "rb") as f:
                existing = f.read(800)
            if _looks_like_python_source(existing):
                return
            os.remove(target)
        except Exception:
            return
    if not str(api).startswith("http"):
        return
    # api 常是 …/foo.py，urljoin 会落到同级 …/t4.py
    dep_url = urljoin(api, os.path.basename(name))
    if not str(dep_url).startswith("http"):
        return
    try:
        with urlopen(dep_url, timeout=30) as response:
            data = response.read()
        if not _looks_like_python_source(data):
            print("[pyrunner] skip non-python dep %s from %s" % (name, dep_url), file=sys.stderr)
            return
        with open(target, "wb") as output:
            output.write(data)
    except Exception as exc:
        print("[pyrunner] download %s failed: %s" % (name, exc), file=sys.stderr)


def _preload_imports_from_source():
    """顶层 import t4 等发生在 init/getDependence 之前，需按源码预拉。

    不把 from base.spider 里的 base 当成要下载的 base.py（TV 用内置包）。
    """
    try:
        with open(script, "r", encoding="utf-8", errors="ignore") as f:
            src = f.read()
    except Exception:
        return
    names = set()
    for m in re.finditer(r"(?:^|\n)\s*(?:import|from)\s+([A-Za-z_][\w]*)", src):
        mod = m.group(1)
        if _is_blocked_dep_name(mod) or _local_package_dir(mod):
            continue
        names.add(mod + ".py")
    # 常见伴侣模块优先
    for extra in ("t4.py", "utils.py", "common.py"):
        if extra.replace(".py", "") in src or extra in names:
            names.add(extra)
    for name in sorted(names):
        _download_dep(name)


_preload_imports_from_source()

spec = importlib.util.spec_from_file_location("kotv_spider_" + site_key, script)
mod = importlib.util.module_from_spec(spec)
sp = None
load_error = None
try:
    spec.loader.exec_module(mod)
    sp = mod.Spider() if hasattr(mod, "Spider") else None
    if sp is not None:
        sp.siteKey = site_key
except Exception as exc:
    load_error = exc
    traceback.print_exc(file=sys.stderr)


def download_dependencies():
 # init 时下载依赖并覆盖写入
    if sp is None or not hasattr(sp, "getDependence"):
        return
    for item in sp.getDependence() or []:
        _download_dep(item)


def encode_result(value):
    if value is None:
        return "{}"
    if isinstance(value, (dict, list)):
        return json.dumps(value, ensure_ascii=False)
    return str(value)


def encode_proxy_result(value):
    """兼容历史安卓实现：localProxy 返回 list，body 可为 bytes。
    JSON-IPC 无法传 bytes，转为 base64 字符串并置 flag=1。
    """
    if value is None:
        return "[]"
    if not isinstance(value, (list, tuple)):
        return encode_result(value)
    out = list(value)
    while len(out) < 3:
        out.append(None)
    body = out[2]
    flag = 0
    if len(out) > 4 and out[4] is not None:
        try:
            flag = int(out[4])
        except Exception:
            flag = 0
    if isinstance(body, memoryview):
        body = body.tobytes()
    if isinstance(body, (bytes, bytearray)):
        out[2] = base64.b64encode(bytes(body)).decode("ascii")
        flag = 1
    elif body is None:
        out[2] = ""
    elif not isinstance(body, (str, int, float, bool, dict, list)):
        out[2] = str(body)
    # headers
    if len(out) < 4:
        out.append({})
    elif out[3] is None:
        out[3] = {}
    elif hasattr(out[3], "items") and not isinstance(out[3], dict):
        try:
            out[3] = {str(k): str(v) for k, v in out[3].items()}
        except Exception:
            out[3] = {}
    while len(out) < 5:
        out.append(None)
    out[4] = flag
    return json.dumps(out, ensure_ascii=False)


def invoke(method, args):
    if load_error is not None:
        raise load_error
    if sp is None and mod is None:
        raise RuntimeError("爬虫模块未加载")
    if sp is None:
        fn = getattr(mod, method, None)
    else:
        fn = getattr(sp, method, None)
        if fn is None and method.endswith("Content"):
            fn = getattr(sp, method.replace("Content", ""), None)
    if fn is None:
        return "{}"
    if method == "init":
        download_dependencies()
        return encode_result(fn(args.get("extend", ext)))
    if method == "homeContent":
        return encode_result(fn(args.get("filter", True)))
    if method == "homeVideoContent":
        return encode_result(fn())
    if method == "categoryContent":
        return encode_result(fn(args.get("tid", ""), args.get("pg", "1"), args.get("filter", True), args.get("extend") or {}))
    if method == "detailContent":
        return encode_result(fn(args.get("ids") or []))
    if method == "searchContent":
        return encode_result(fn(args.get("key", ""), args.get("quick", False), args.get("pg", "1")))
    if method == "playerContent":
        return encode_result(fn(args.get("flag", ""), args.get("id", ""), args.get("vipFlags") or []))
    if method == "liveContent":
        return encode_result(fn(args.get("url", "")))
    if method == "localProxy":
        return encode_proxy_result(fn(args.get("params") or {}))
    if method == "action":
        return encode_result(fn(args.get("action", "")))
    if method == "isVideoFormat":
        return encode_result(fn(args.get("url", "")))
    if method == "manualVideoCheck":
        return encode_result(fn())
    if method == "destroy":
        return encode_result(fn())
    return encode_result(fn())


def kotv_dispatch_json(line):
    """供 CGO 嵌入 CPython 调用：单行 JSON 请求 → JSON 响应字符串。"""
    line = (line or "").strip()
    if not line:
        return json.dumps({"id": None, "ok": False, "error": "empty request"}, ensure_ascii=False)
    req = json.loads(line)
    try:
        result = invoke(req.get("method", ""), req.get("args") or {})
        return json.dumps({"id": req.get("id"), "ok": True, "result": result}, ensure_ascii=False)
    except Exception as exc:
        traceback.print_exc(file=sys.stderr)
        return json.dumps({"id": req.get("id"), "ok": False, "error": str(exc)}, ensure_ascii=False)


def kotv_repl():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        print(kotv_dispatch_json(line), flush=True)


if __name__ == "__main__":
    kotv_repl()
