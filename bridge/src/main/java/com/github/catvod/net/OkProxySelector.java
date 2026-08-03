package com.github.catvod.net;

import com.github.catvod.bean.Proxy;
import com.github.catvod.utils.Util;

import java.io.IOException;
import java.net.Authenticator;
import java.net.ProxySelector;
import java.net.SocketAddress;
import java.net.URI;
import java.util.List;

public class OkProxySelector extends ProxySelector {

    private final ProxySelector system;
    private boolean authSet;

    public OkProxySelector() {
        system = ProxySelector.getDefault();
        Authenticator.setDefault(new ProxyAuthenticator(this));
        authSet = true;
    }

    public synchronized void addAll(List<Proxy> items) {
        put("", items);
    }

    public synchronized void put(String clientId, List<Proxy> items) {
        NetProfiles.Profile p = NetProfiles.put(clientId);
        p.proxies.clear();
        if (items == null || items.isEmpty()) return;
        items.forEach(Proxy::init);
        p.proxies.addAll(items);
        p.proxies.sort(null);
        if (!authSet) {
            Authenticator.setDefault(new ProxyAuthenticator(this));
            authSet = true;
        }
    }

    public synchronized void clear() {
        NetProfiles.Profile p = NetProfiles.put("");
        p.proxies.clear();
    }

    public synchronized void clearAll() {
        Authenticator.setDefault(null);
        authSet = false;
        for (NetProfiles.Profile p : NetProfiles.snapshot().values()) {
            p.proxies.clear();
        }
    }

    /** ProxyAuthenticator 用：当前线程 clientId 对应的代理规则。 */
    public List<Proxy> getProxy() {
        return NetProfiles.get(Util.clientId()).proxies;
    }

    private List<java.net.Proxy> fallback(URI uri) {
        return system != null ? system.select(uri) : List.of(java.net.Proxy.NO_PROXY);
    }

    @Override
    public List<java.net.Proxy> select(URI uri) {
        List<Proxy> proxy = getProxy();
        if (proxy.isEmpty() || uri.getHost() == null || "127.0.0.1".equals(uri.getHost())) return fallback(uri);
        for (Proxy item : proxy) for (String host : item.getHosts()) if (Util.containOrMatch(uri.getHost(), host)) return !item.getProxies().isEmpty() ? item.getProxies() : fallback(uri);
        return fallback(uri);
    }

    @Override
    public void connectFailed(URI uri, SocketAddress socketAddress, IOException e) {
        if (system != null) system.connectFailed(uri, socketAddress, e);
    }
}
