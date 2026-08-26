package com.github.catvod.net;

import com.github.catvod.bean.Doh;
import com.github.catvod.bean.Header;
import com.github.catvod.bean.Proxy;

import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * 按 ScopeID（优先 userId）隔离点播配置里的 headers / proxy / hosts / doh。
 * 空 key 为默认桶（本机单用户兼容）。
 */
public final class NetProfiles {

    public static final class Profile {
        public final List<Header> headers = new CopyOnWriteArrayList<>();
        public final List<Proxy> proxies = new CopyOnWriteArrayList<>();
        public final ConcurrentHashMap<String, String> hosts = new ConcurrentHashMap<>();
        public volatile Doh doh;
    }

    private static final ConcurrentHashMap<String, Profile> BY_CLIENT = new ConcurrentHashMap<>();

    /**
     * 最近活跃的非空 Scope。jar 常自起线程/线程池发请求，ThreadLocal clientId 丢失后
     * 若落到空默认桶会把 headers/hosts/doh 全丢（TV 是全局一份不存在此问题）；
     * 单前端场景用最近活跃桶兜底即等价 TV 语义。
     */
    private static volatile String lastActive = "";

    private NetProfiles() {}

    public static String key(String clientId) {
        return clientId == null ? "" : clientId.trim();
    }

    /** SpiderBridge 每次调用绑定 clientId 时记录，供无绑定线程兜底。 */
    public static void touch(String clientId) {
        String k = key(clientId);
        if (!k.isEmpty()) lastActive = k;
    }

    public static Profile get(String clientId) {
        String k = key(clientId);
        Profile p = BY_CLIENT.get(k);
        if (p != null) return p;
        if (!k.isEmpty()) {
            p = BY_CLIENT.get("");
            if (p != null) return p;
        } else {
            String la = lastActive;
            if (!la.isEmpty()) {
                p = BY_CLIENT.get(la);
                if (p != null) return p;
            }
        }
        return BY_CLIENT.computeIfAbsent("", x -> new Profile());
    }

    public static Profile put(String clientId) {
        return BY_CLIENT.computeIfAbsent(key(clientId), x -> new Profile());
    }

    public static void replace(String clientId, List<Header> headers, List<Proxy> proxies,
                               Map<String, String> hosts, Doh doh) {
        Profile p = put(clientId);
        p.headers.clear();
        if (headers != null && !headers.isEmpty()) p.headers.addAll(headers);
        p.proxies.clear();
        if (proxies != null && !proxies.isEmpty()) {
            proxies.forEach(Proxy::init);
            p.proxies.addAll(proxies);
            p.proxies.sort(null);
        }
        p.hosts.clear();
        if (hosts != null && !hosts.isEmpty()) p.hosts.putAll(hosts);
        p.doh = doh;
    }

    public static void clearAll() {
        BY_CLIENT.clear();
    }

    public static Map<String, Profile> snapshot() {
        return Collections.unmodifiableMap(BY_CLIENT);
    }
}
