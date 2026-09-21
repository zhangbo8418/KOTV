import json
import os
import re
import sys
import time
from abc import ABCMeta, abstractmethod
from importlib.machinery import SourceFileLoader

import requests
from lxml import etree


def _cache_root():
    return os.environ.get("KOTV_PY_CACHE", os.path.dirname(os.path.dirname(__file__)))


class Spider(metaclass=ABCMeta):
    _instance = None

    def __new__(cls, *args, **kwargs):
        # 必须写在子类自己的 __dict__：否则多站点共用基类 _instance，Android 会话缓存会串源。
        inst = cls.__dict__.get("_instance")
        if inst is None:
            inst = super().__new__(cls)
            cls._instance = inst
        return inst

    def __init__(self):
        self.extend = ""
        self.siteKey = ""

    @abstractmethod
    def init(self, extend=""):
        pass

    def homeContent(self, filter):
        pass

    def homeVideoContent(self):
        pass

    def categoryContent(self, tid, pg, filter, extend):
        pass

    def detailContent(self, ids):
        pass

    def searchContent(self, key, quick, pg="1"):
        pass

    def playerContent(self, flag, id, vipFlags):
        pass

    def localProxy(self, param):
        pass

    def action(self, action):
        pass

    def destroy(self):
        pass

    def getDependence(self):
        return []

    def getName(self):
        return ""

    def liveContent(self, url):
        pass

    def isVideoFormat(self, url):
        pass

    def manualVideoCheck(self):
        pass

    def loadSpider(self, name):
        return self.loadModule(name).Spider()

    def loadModule(self, name):
        path = os.path.join(_cache_root(), f"{name}.py")
        return SourceFileLoader(name, path).load_module()

    def fetch(self, url, params=None, cookies=None, headers=None, timeout=5, verify=True,
              stream=False, allow_redirects=True):
        response = requests.get(
            url, params=params, cookies=cookies, headers=headers, timeout=timeout,
            verify=verify, stream=stream, allow_redirects=allow_redirects,
        )
        response.encoding = "utf-8"
        return response

    def post(self, url, params=None, data=None, json=None, cookies=None, headers=None,
             timeout=5, verify=True, stream=False, allow_redirects=True):
        response = requests.post(
            url, params=params, data=data, json=json, cookies=cookies, headers=headers,
            timeout=timeout, verify=verify, stream=stream, allow_redirects=allow_redirects,
        )
        response.encoding = "utf-8"
        return response

    def html(self, content):
        return etree.HTML(content)

    def str2json(self, text):
        return json.loads(text)

    def json2str(self, value):
        return json.dumps(value, ensure_ascii=False)

    def regStr(self, pattern, source, group=1):
        match = re.search(pattern, source)
        return match.group(group) if match else ""

    def removeHtmlTags(self, source):
        return re.sub(r"<.*?>", "", source)

    def cleanText(self, source):
        return re.sub(
            "[\U0001F600-\U0001F64F\U0001F300-\U0001F5FF"
            "\U0001F680-\U0001F6FF\U0001F1E0-\U0001F1FF]",
            "",
            source,
        )

    def getProxyUrl(self, local=True):
        port = os.environ.get("KOTV_PROXY_PORT", "9978")
        if local:
            host = "127.0.0.1"
        else:
            host = (os.environ.get("KOTV_PROXY_HOST") or "").strip() or "127.0.0.1"
        return f"http://{host}:{port}/proxy?do=py"

    def log(self, message):
        if isinstance(message, (dict, list)):
            message = json.dumps(message, ensure_ascii=False)
        print(message, file=sys.stderr, flush=True)

    def _cache_base(self):
        port = os.environ.get("KOTV_PROXY_PORT", "9978")
        return f"http://127.0.0.1:{port}/cache"

    def getCache(self, key):
        # TV：GET /cache?do=get&key= → Prefers/LocalGet（rule 空 → cache_{key}）
        try:
            value = self.fetch(
                f"{self._cache_base()}?do=get&key={key}", timeout=5
            ).text
        except Exception:
            return None
        if len(value) > 0:
            if (value.startswith("{") and value.endswith("}")) or (
                value.startswith("[") and value.endswith("]")
            ):
                try:
                    value = json.loads(value)
                except Exception:
                    return value
                if isinstance(value, dict):
                    if "expiresAt" not in value or value["expiresAt"] >= int(time.time()):
                        return value
                    self.delCache(key)
                    return None
            return value
        return None

    def setCache(self, key, value):
        if isinstance(value, (int, float)):
            value = str(value)
        if value is not None and len(str(value)) > 0:
            if isinstance(value, (dict, list)):
                value = json.dumps(value, ensure_ascii=False)
        try:
            r = self.post(
                f"{self._cache_base()}?do=set&key={key}",
                data={"value": value},
                timeout=5,
            )
            return "succeed" if r.status_code == 200 else "failed"
        except Exception:
            return "failed"

    def delCache(self, key):
        try:
            r = self.fetch(f"{self._cache_base()}?do=del&key={key}", timeout=5)
            return "succeed" if r.status_code == 200 else "failed"
        except Exception:
            return "failed"
