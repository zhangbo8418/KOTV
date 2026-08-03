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

    private NetProfiles() {}

    public static String key(String clientId) {
        return clientId == null ? "" : clientId.trim();
    }

    public static Profile get(String clientId) {
        String k = key(clientId);
        Profile p = BY_CLIENT.get(k);
        if (p != null) return p;
        if (!k.isEmpty()) {
            p = BY_CLIENT.get("");
            if (p != null) return p;
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
