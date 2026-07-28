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

const PARSE_CACHE = true;
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

class Jsoup {
  constructor(myUrl = "") {
    this.MY_URL = myUrl;
    this.pdfa_html = "";
    this.pdfa_doc = null;
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
    // 对齐 jar Function：以 / 开头走 xpath
    if (parse.startsWith("/") && typeof globalThis.__xpathList === "function") {
      const list = globalThis.__xpathList(html, parse);
      return Array.isArray(list) ? list : [];
    }
    parse = parseHikerToJq(parse, false);
    const doc = load(html);
    if (PARSE_CACHE && this.pdfa_html !== html) {
      this.pdfa_html = html;
      this.pdfa_doc = doc;
    }
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

  pdfl(html, parse, listText, listUrl, _urlKey) {
    if (!html || !parse) return [];
    if (parse.startsWith("/") && typeof globalThis.__xpathList === "function") {
      const nodes = globalThis.__xpathList(html, parse);
      if (!Array.isArray(nodes) || nodes.length === 0) return [];
      const out = [];
      for (const fragment of nodes) {
        const title = this.pdfh(fragment, listText || "body&&Text");
        const href = this.pd(fragment, listUrl || "a&&href", this.MY_URL);
        out.push(`${title}$${href}`);
      }
      return out;
    }
    parse = parseHikerToJq(parse, false);
    const doc = load(html);
    const parses = parse.split(" ");
    let ret = null;
    for (const pars of parses) {
      ret = this.parseOneRule(doc, pars, ret);
      if (!ret || ret.length === 0) return [];
    }
    const out = [];
    ret.each((_, el) => {
      const fragment = doc.html(el) || "";
      const sub = load(fragment);
      const title = this.pdfh(fragment, listText || "body&&Text");
      const href = this.pd(fragment, listUrl || "a&&href", this.MY_URL);
      out.push(`${title}$${href}`);
      void sub;
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
        // 属性：用节点 outerHTML 再走 CSS 取属性
        const node = globalThis.__xpathHtml(html, expr) || "";
        if (!node) return "";
        return this.pdfh(node, "body&&" + option, baseUrl);
      }
      return globalThis.__xpathHtml(html, expr) || "";
    }
    const doc = load(html);
    if (PARSE_CACHE && this.pdfa_html !== html) {
      this.pdfa_html = html;
      this.pdfa_doc = doc;
    }
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
    // 对齐 jar Function.pd：pdfh 后再 joinUrl(base, result)
    if (!baseUrl) baseUrl = this.MY_URL;
    const result = this.pdfh(html, parse, "");
    if (!result) return "";
    if (!baseUrl) return result;
    if (test(SPECIAL_URL, result)) return result;
    return resolveUrl(baseUrl, result);
  }
}

function pdfh(html, parse, baseUrl) {
  if (typeof globalThis.__jarPdfh === "function") {
    try {
      const v = globalThis.__jarPdfh(html, parse);
      if (v !== undefined && v !== null) return v;
    } catch (_) {}
  }
  return new Jsoup(baseUrl || globalThis.MY_URL || "").pdfh(html, parse, baseUrl || "");
}
function pdfa(html, parse) {
  if (typeof globalThis.__jarPdfa === "function") {
    try {
      const v = globalThis.__jarPdfa(html, parse);
      if (Array.isArray(v)) return v;
    } catch (_) {}
  }
  return new Jsoup().pdfa(html, parse);
}
function pd(html, parse, baseUrl) {
  if (typeof globalThis.__jarPd === "function") {
    try {
      const v = globalThis.__jarPd(html, parse, baseUrl || globalThis.MY_URL || "");
      if (v !== undefined && v !== null) return v;
    } catch (_) {}
  }
  return new Jsoup(baseUrl || globalThis.MY_URL || "").pd(html, parse, baseUrl || "");
}
function pdfl(html, parse, listText, listUrl, urlKey) {
  if (typeof globalThis.__jarPdfl === "function") {
    try {
      const v = globalThis.__jarPdfl(html, parse, listText, listUrl, urlKey);
      if (Array.isArray(v)) return v;
    } catch (_) {}
  }
  return new Jsoup().pdfl(html, parse, listText, listUrl, urlKey);
}

globalThis.pdfh = pdfh;
globalThis.pdfa = pdfa;
globalThis.pd = pd;
globalThis.pdfl = pdfl;
