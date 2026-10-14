/**
 * CatVod/海阔 html 解析宿主（对应 jar com.github.catvod.js.Function）。
 * 在加载 drpy2 等脚本前注入 globalThis.pdfh / pdfa / pd / pdfl。
 */
import * as cheerioMod from "./cheerio.min.js";

const load =
  typeof cheerioMod.load === "function"
    ? cheerioMod.load
    : typeof cheerioMod.default?.load === "function"
      ? cheerioMod.default.load
      : typeof cheerioMod.default === "function"
        ? cheerioMod.default
        : null;

if (!load) {
  throw new Error("cheerio.load unavailable");
}

globalThis.cheerio = cheerioMod.default ?? cheerioMod;

const NOADD_INDEX =
  ":eq|:lt|:gt|:first|:last|:not|:even|:odd|:has|:contains|:matches|:empty|^body$|^#";
const URLJOIN_ATTR = "(url|src|href|-original|-src|-play|-url|style)$|^(data-|url-|src-)";
const SPECIAL_URL = "^(ftp|magnet|thunder|ws):";

function test(re, str) {
  return new RegExp(re, "im").test(str || "");
}

function parseHikerToJq(parse, first) {
  if ((parse || "").includes("&&")) {
    const parses = parse.split("&&");
    const out = [];
    for (let i = 0; i < parses.length; i++) {
      const psList = parses[i].split(" ");
      const ps = psList[psList.length - 1];
      if (!test(NOADD_INDEX, ps)) {
        if (!first && i >= parses.length - 1) out.push(parses[i]);
        else out.push(`${parses[i]}:eq(0)`);
      } else out.push(parses[i]);
    }
    return out.join(" ");
  }
  const psList = parse.split(" ");
  const ps = psList[psList.length - 1];
  if (!test(NOADD_INDEX, ps) && first) return `${parse}:eq(0)`;
  return parse;
}

function getParseInfo(nparse) {
  let excludes = [];
  let nparseIndex = 0;
  let nparseRule = nparse;
  if (nparse.includes(":eq")) {
    nparseRule = nparse.split(":eq")[0];
    let nparsePos = nparse.split(":eq")[1];
    if (nparseRule.includes("--")) {
      excludes = nparseRule.split("--").slice(1);
      nparseRule = nparseRule.split("--")[0];
    } else if (nparsePos.includes("--")) {
      excludes = nparsePos.split("--").slice(1);
      nparsePos = nparsePos.split("--")[0];
    }
    try {
      nparseIndex = parseInt(nparsePos.split("(")[1].split(")")[0], 10);
    } catch (_) {}
  } else if (nparse.includes("--")) {
    nparseRule = nparse.split("--")[0];
    excludes = nparse.split("--").slice(1);
  }
  return { nparseRule, nparseIndex, excludes };
}

function reorderAdjacentLtAndGt(selector) {
  const adjacentPattern = /:gt\((\d+)\):lt\((\d+)\)/;
  let match = adjacentPattern.exec(selector);
  while (match !== null) {
    const replacement = `:lt(${match[2]}):gt(${match[1]})`;
    selector =
      selector.substring(0, match.index) +
      replacement +
      selector.substring(match.index + match[0].length);
    adjacentPattern.lastIndex = match.index;
    match = adjacentPattern.exec(selector);
  }
  return selector;
}

function parseText(text) {
  text = (text || "").replace(/\s+/g, "\n");
  text = text.replace(/\n+/g, "\n").replace(/^\s+/, "");
  return text.replace(/\n/g, " ");
}

function resolveUrl(base, rel) {
  if (typeof globalThis.joinUrl === "function") return globalThis.joinUrl(base, rel);
  try {
    return new URL(rel, base).href;
  } catch (_) {
    return rel;
  }
}

/** 同 html 复用 Document；顶层函数共用一份。 */
const docCache = {
  pdfhHtml: "",
  pdfhDoc: null,
  pdfaHtml: "",
  pdfaDoc: null,
  getPdfh(html) {
    if (html === this.pdfhHtml && this.pdfhDoc) return this.pdfhDoc;
    this.pdfhDoc = load(html);
    this.pdfhHtml = html;
    return this.pdfhDoc;
  },
  getPdfa(html) {
    if (html === this.pdfaHtml && this.pdfaDoc) return this.pdfaDoc;
    this.pdfaDoc = load(html);
    this.pdfaHtml = html;
    return this.pdfaDoc;
  },
};

class Jsoup {
  constructor(myUrl = "") {
    this.MY_URL = myUrl;
  }

  parseOneRule(doc, nparse, ret) {
    let { nparseRule, nparseIndex, excludes } = getParseInfo(nparse);
    nparseRule = reorderAdjacentLtAndGt(nparseRule);
    if (!ret) ret = doc(nparseRule);
    else ret = ret.find(nparseRule);
    if (nparse.includes(":eq")) ret = ret.eq(nparseIndex);
    if (excludes.length > 0 && ret) {
      ret = ret.clone();
      for (const exclude of excludes) ret.find(exclude).remove();
    }
    return ret;
  }

  pdfa(html, parse) {
    if (!html || !parse) return [];
    if (parse.startsWith("/") && typeof globalThis.__xpathList === "function") {
      const list = globalThis.__xpathList(html, parse);
      return Array.isArray(list) ? list : [];
    }
    parse = parseHikerToJq(parse, false);
    const doc = docCache.getPdfa(html);
    const parses = parse.split(" ");
    let ret = null;
    for (const nparse of parses) {
      ret = this.parseOneRule(doc, nparse, ret);
      if (!ret || ret.length === 0) return [];
    }
    const res = [];
    ret.each((_, el) => {
      res.push(doc.html(el) || "");
    });
    return res;
  }

  pdfl(html, parse, listText, listUrl, urlKey) {
    if (!html || !parse) return [];
    const base = urlKey || this.MY_URL || globalThis.MY_URL || "";
    if (parse.startsWith("/") && typeof globalThis.__xpathList === "function") {
      const nodes = globalThis.__xpathList(html, parse);
      if (!Array.isArray(nodes) || nodes.length === 0) return [];
      const out = [];
      for (const fragment of nodes) {
        const title = this.pdfh(fragment, listText || "body&&Text");
        const href = this.pd(fragment, listUrl || "a&&href", base);
        out.push(`${title}$${href}`);
      }
      return out;
    }
    parse = parseHikerToJq(parse, false);
    const doc = docCache.getPdfa(html);
    const parses = parse.split(" ");
    let ret = null;
    for (const pars of parses) {
      ret = this.parseOneRule(doc, pars, ret);
      if (!ret || ret.length === 0) return [];
    }
    const out = [];
    ret.each((_, el) => {
      const fragment = doc.html(el) || "";
      const title = this.pdfh(fragment, listText || "body&&Text");
      const href = this.pd(fragment, listUrl || "a&&href", base);
      out.push(`${title}$${href}`);
    });
    return out;
  }

  pdfh(html, parse, baseUrl = "") {
    if (!html || !parse) return "";
    if (parse.startsWith("/") && typeof globalThis.__xpathHtml === "function") {
      let option = "";
      let expr = parse;
      if (parse.includes("&&")) {
        const parts = parse.split("&&");
        option = parts[parts.length - 1];
        expr = parts.slice(0, -1).join("&&");
      }
      if (option === "Text" || option === "text()") {
        return parseText(globalThis.__xpathText(html, expr) || "");
      }
      if (option === "Html" || option === "html()") {
        return globalThis.__xpathHtml(html, expr) || "";
      }
      if (option && option !== "Text" && option !== "Html") {
        const node = globalThis.__xpathHtml(html, expr) || "";
        if (!node) return "";
        return this.pdfh(node, "body&&" + option, baseUrl);
      }
      return globalThis.__xpathHtml(html, expr) || "";
    }
    const doc = docCache.getPdfh(html);
    if (parse === "body&&Text" || parse === "Text") return parseText(doc.text());
    if (parse === "body&&Html" || parse === "Html") return doc.html() || "";

    let option;
    if (parse.includes("&&")) {
      const parts = parse.split("&&");
      option = parts[parts.length - 1];
      parse = parts.slice(0, -1).join("&&");
    }
    parse = parseHikerToJq(parse, true);
    const parses = parse.split(" ");
    let ret = null;
    for (const nparse of parses) {
      ret = this.parseOneRule(doc, nparse, ret);
      if (!ret || ret.length === 0) return "";
    }
    if (option) {
      switch (option) {
        case "Text":
          return parseText(ret.text() || "");
        case "Html":
          return ret.html() || "";
        default: {
          const original = ret.clone();
          const options = option.split("||");
          for (const opt of options) {
            let val = original.attr(opt) || "";
            if (/style/i.test(opt) && val.includes("url(")) {
              const m = val.match(/url\((.*?)\)/);
              if (m) val = m[1].replace(/^['"]|['"]$/g, "");
            }
            if (val && baseUrl) {
              const needAdd = test(URLJOIN_ATTR, opt) && !test(SPECIAL_URL, val);
              if (needAdd) {
                if (val.includes("http")) val = val.slice(val.indexOf("http"));
                else val = resolveUrl(baseUrl, val);
              }
            }
            if (val) return val;
          }
          return "";
        }
      }
    }
    return doc.html(ret.get(0)) || "";
  }

  pd(html, parse, baseUrl = "") {
    if (!baseUrl) baseUrl = this.MY_URL;
    const result = this.pdfh(html, parse, "");
    if (!result) return "";
    if (!baseUrl) return result;
    if (test(SPECIAL_URL, result)) return result;
    return resolveUrl(baseUrl, result);
  }
}

/** 模块级单例：避免每次 pdf* 新建实例导致 Document 缓存失效。 */
const shared = new Jsoup();

function pdfh(html, parse, baseUrl) {
  // 优先进程内 cheerio。Android 上 __jarPdf* 走 :9979 RPC，实测单次 pdfa ~2–3s。
  try {
    shared.MY_URL = baseUrl || globalThis.MY_URL || "";
    return shared.pdfh(html, parse, baseUrl || "");
  } catch (_) {}
  if (typeof globalThis.__jarPdfh === "function") {
    try {
      const v = globalThis.__jarPdfh(html, parse);
      if (v !== undefined && v !== null) return v;
    } catch (_) {}
  }
  return "";
}
function pdfa(html, parse) {
  try {
    return shared.pdfa(html, parse);
  } catch (_) {}
  if (typeof globalThis.__jarPdfa === "function") {
    try {
      const v = globalThis.__jarPdfa(html, parse);
      if (Array.isArray(v)) return v;
    } catch (_) {}
  }
  return [];
}
function pd(html, parse, baseUrl) {
  try {
    shared.MY_URL = baseUrl || globalThis.MY_URL || "";
    return shared.pd(html, parse, baseUrl || "");
  } catch (_) {}
  if (typeof globalThis.__jarPd === "function") {
    try {
      const v = globalThis.__jarPd(html, parse, baseUrl || globalThis.MY_URL || "");
      if (v !== undefined && v !== null) return v;
    } catch (_) {}
  }
  return "";
}
function pdfl(html, parse, listText, listUrl, urlKey) {
  const base = urlKey || globalThis.MY_URL || "";
  try {
    shared.MY_URL = base;
    return shared.pdfl(html, parse, listText, listUrl, base);
  } catch (_) {}
  if (typeof globalThis.__jarPdfl === "function") {
    try {
      const v = globalThis.__jarPdfl(html, parse, listText, listUrl, base);
      if (Array.isArray(v)) return v;
    } catch (_) {}
  }
  return [];
}

globalThis.pdfh = pdfh;
globalThis.pdfa = pdfa;
globalThis.pd = pd;
globalThis.pdfl = pdfl;
