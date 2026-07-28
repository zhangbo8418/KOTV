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


def _ensure_bundled_site_packages():
    """Windows embed 的 python*._pth 常忽略 PYTHONPATH；显式把 Lib/site-packages 塞进 sys.path。"""
    exe = os.path.abspath(sys.executable)
    exe_dir = os.path.dirname(exe)
    # install_only / embed 布局
    _prepend_sys_path(
        os.path.join(exe_dir, "Lib", "site-packages"),
        os.path.join(exe_dir, "lib", "site-packages"),
        os.path.join(exe_dir, "lib", "python%d.%d" % sys.version_info[:2], "site-packages"),
    )
    # 少数布局：python.exe 在 Scripts/ 下
    parent = os.path.dirname(exe_dir)
    _prepend_sys_path(
        os.path.join(parent, "Lib", "site-packages"),
        os.path.join(parent, "lib", "site-packages"),
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


def _download_dep(name):
    """从爬虫 api 同目录拉取依赖 py 到 cache（失败忽略，由后续 import 报错）。"""
    name = name if str(name).endswith(".py") else str(name) + ".py"
    target = os.path.join(cache, os.path.basename(name))
    if os.path.isfile(target) and os.path.getsize(target) > 0:
        return
    if not str(api).startswith("http"):
        return
    # api 常是 …/foo.py，urljoin 会落到同级 …/t4.py
    dep_url = urljoin(api, os.path.basename(name))
    if not str(dep_url).startswith("http"):
        return
    try:
        with urlopen(dep_url, timeout=30) as response, open(target, "wb") as output:
            output.write(response.read())
    except Exception as exc:
        print("[pyrunner] download %s failed: %s" % (name, exc), file=sys.stderr)


def _preload_imports_from_source():
    """顶层 import t4 等发生在 init/getDependence 之前，需按源码预拉。"""
    try:
        with open(script, "r", encoding="utf-8", errors="ignore") as f:
            src = f.read()
    except Exception:
        return
    names = set()
    for m in re.finditer(r"(?:^|\n)\s*(?:import|from)\s+([A-Za-z_][\w]*)", src):
        mod = m.group(1)
        if mod in ("base", "os", "sys", "re", "json", "time", "requests", "lxml", "Crypto",
                   "urllib", "urllib3", "bs4", "beautifulsoup4", "hashlib", "base64",
                   "datetime", "collections", "typing", "math", "random", "copy", "html",
                   "xml", "http", "ssl", "socket", "threading", "traceback", "importlib"):
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


for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    req = json.loads(line)
    try:
        result = invoke(req.get("method", ""), req.get("args") or {})
        print(json.dumps({"id": req.get("id"), "ok": True, "result": result}, ensure_ascii=False), flush=True)
    except Exception as exc:
        traceback.print_exc(file=sys.stderr)
        print(json.dumps({"id": req.get("id"), "ok": False, "error": str(exc)}, ensure_ascii=False), flush=True)
