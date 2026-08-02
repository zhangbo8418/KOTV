package com.github.catvod.net;

import org.apache.commons.lang3.StringUtils;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

public class OkResult {

    private final int code;
    private final String body;
    private final Map<String, List<String>> resp;

    public OkResult() {
        this.code = 500;
        this.body = "";
        this.resp = new HashMap<>();
    }

    public OkResult(int code, String body, Map<String, List<String>> resp) {
        this.code = code;
        this.body = body;
        this.resp = resp;
    }

    public int getCode() {
        return code;
    }

    public String getBody() {
        return StringUtils.isEmpty(body) ? "" : body;
    }

    public Map<String, List<String>> getResp() {
        return resp;
    }

    /** OkHttp toMultimap 的 header 名为小写；历史代码常用 set-Cookie，统一兼容。 */
    public List<String> getHeader(String name) {
        if (resp == null || name == null) return null;
        List<String> values = resp.get(name);
        if (values != null) return values;
        values = resp.get(name.toLowerCase());
        if (values != null) return values;
        for (Map.Entry<String, List<String>> e : resp.entrySet()) {
            if (e.getKey() != null && e.getKey().equalsIgnoreCase(name)) return e.getValue();
        }
        return null;
    }
}
