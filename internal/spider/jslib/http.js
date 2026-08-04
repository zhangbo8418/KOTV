let req = (url, options) => {
    options = options || {};
    // 与 drpy request() 对齐：在调用宿主前规范化，并写回调用方对象（withHeaders 等）。
    if (options.redirect === false) {
        options.redirect = 0;
    }
    if (options.onlyHeaders) {
        options.redirect = 0;
        options.withHeaders = true;
    }
    const res = http(url, Object.assign({ async: false }, options)) || {
        code: "",
        content: "",
        headers: {},
    };
    // Marshal 出的 headers 可能不可扩展；drpy 会写 body/url，必须换成普通对象。
    const headers = Object.assign({}, res.headers || {});
    if (options.onlyHeaders) {
        const loc = headers.location || headers.Location || "";
        if (loc) {
            headers.url = String(loc).replace(/ /g, "+");
        }
    }
    return Object.assign({}, res, { headers });
};

function http(url, options = {}) {
    if (options?.async === false) return _http(url, options)
    return new Promise(resolve => _http(url, Object.assign({
        complete: res => resolve(res)
    }, options))).catch(err => {
        console.error(err.name, err.message, err.stack)
        return {
            ok: false,
            status: 500,
            url
        }
    })
}

function defineGlobalAlias(name) {
    const descriptor = Object.getOwnPropertyDescriptor(globalThis, name);
    if (descriptor && !descriptor.configurable) return;
    Object.defineProperty(globalThis, name, {
        enumerable: true,
        configurable: true,
        get() {
            return globalThis;
        },
        set() {}
    });
}

['global', 'window', 'self'].forEach(defineGlobalAlias);

// 暴露 http，供 spider.js / 严格模块作用域使用（TV 用 let req + 自由变量 http）。
globalThis.http = http;
globalThis.req = req;
