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
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance

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

    def fetch(self, url, params=None, cookies=None, headers=None, timeout=10, verify=False,
              stream=False, allow_redirects=True):
        response = requests.get(
            url, params=params, cookies=cookies, headers=headers, timeout=timeout,
            verify=verify, stream=stream, allow_redirects=allow_redirects,
        )
        response.encoding = "utf-8"
        return response

    def post(self, url, params=None, data=None, json=None, cookies=None, headers=None,
             timeout=10, verify=False, stream=False, allow_redirects=True):
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
 # getProxyUrl；附加 siteKey 以便桌面端精确路由。
        host = "127.0.0.1" if local else "0.0.0.0"
        port = os.environ.get("KOTV_PROXY_PORT", "9978")
        key = getattr(self, "siteKey", "") or ""
        if key:
            return f"http://{host}:{port}/proxy?do=py&siteKey={key}"
        return f"http://{host}:{port}/proxy?do=py"

    def log(self, message):
        if isinstance(message, (dict, list)):
            message = json.dumps(message, ensure_ascii=False)
        print(message, file=sys.stderr, flush=True)

    def _cache_file(self, key):
        directory = os.path.join(_cache_root(), "kv")
        os.makedirs(directory, exist_ok=True)
        safe = re.sub(r"[^a-zA-Z0-9._-]", "_", key)
        return os.path.join(directory, safe + ".json")

    def getCache(self, key):
        path = self._cache_file(key)
        if not os.path.isfile(path):
            return None
        with open(path, "r", encoding="utf-8") as source:
            raw = source.read()
        if not raw:
            return None
        try:
            value = json.loads(raw)
            if isinstance(value, dict) and "expiresAt" in value:
                if value["expiresAt"] < int(time.time()):
                    self.delCache(key)
                    return None
            return value
        except Exception:
            return raw

    def setCache(self, key, value):
        with open(self._cache_file(key), "w", encoding="utf-8") as output:
            if isinstance(value, (dict, list)):
                json.dump(value, output, ensure_ascii=False)
            else:
                output.write("" if value is None else str(value))
        return "succeed"

    def delCache(self, key):
        path = self._cache_file(key)
        if os.path.exists(path):
            os.remove(path)
        return "succeed"
