# Persistent CatVod Python spider runner for KOTV.
import importlib.util
import json
import os
import ssl
import sys
import traceback


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

for path in (cache, os.path.dirname(script)):
    if path not in sys.path:
        sys.path.insert(0, path)

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
        name = item if str(item).endswith(".py") else str(item) + ".py"
        target = os.path.join(cache, os.path.basename(name))
        dep_url = urljoin(api, name)
        if not str(dep_url).startswith("http"):
            continue
        with urlopen(dep_url, timeout=30) as response, open(target, "wb") as output:
            output.write(response.read())


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
