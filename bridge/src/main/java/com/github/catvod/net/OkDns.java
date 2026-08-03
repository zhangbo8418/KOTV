package com.github.catvod.net;

import androidx.annotation.NonNull;

import com.github.catvod.bean.Doh;
import com.github.catvod.utils.Util;

import java.net.InetAddress;
import java.net.UnknownHostException;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.TimeUnit;
import java.util.stream.Collectors;

import okhttp3.Dns;
import okhttp3.HttpUrl;
import okhttp3.OkHttpClient;
import okhttp3.dnsoverhttps.DnsOverHttps;

public class OkDns implements Dns {

    /** DoH unreachable (common when Google/CF blocked); stick to system DNS after first failure. */
    private volatile boolean dohUnavailable;
    private final ConcurrentHashMap<String, DnsOverHttps> dohCache = new ConcurrentHashMap<>();

    public OkDns() {}

    public void setDoh(Doh item) {
        putDoh("", item);
    }

    public void putDoh(String clientId, Doh item) {
        NetProfiles.Profile p = NetProfiles.put(clientId);
        if (item == null || item.getUrl().isEmpty()) {
            p.doh = null;
            return;
        }
        dohUnavailable = false;
        p.doh = item;
    }

    public void clear() {
        NetProfiles.Profile p = NetProfiles.put("");
        p.hosts.clear();
        p.doh = null;
    }

    public void clearAll() {
        for (NetProfiles.Profile p : NetProfiles.snapshot().values()) {
            p.hosts.clear();
            p.doh = null;
        }
        dohCache.clear();
    }

    public void addAll(List<String> hosts) {
        putHosts("", hosts);
    }

    public void putHosts(String clientId, List<String> hosts) {
        NetProfiles.Profile p = NetProfiles.put(clientId);
        p.hosts.clear();
        if (hosts == null || hosts.isEmpty()) return;
        p.hosts.putAll(hosts.stream().filter(Objects::nonNull).map(host -> host.split("=", 2)).filter(splits -> splits.length == 2).collect(Collectors.toMap(s -> s[0].trim(), s -> s[1].trim(), (oldHost, newHost) -> newHost)));
    }

    private String get(String hostname, Map<String, String> map) {
        String target = map.get(hostname);
        if (target != null) return target;
        for (Map.Entry<String, String> entry : map.entrySet()) if (Util.containOrMatch(hostname, entry.getKey())) return entry.getValue();
        return hostname;
    }

    private DnsOverHttps dohClient(Doh item) {
        if (item == null || item.getUrl().isEmpty()) return null;
        return dohCache.computeIfAbsent(item.getUrl(), url -> {
            OkHttpClient client = new OkHttpClient.Builder()
                    .connectTimeout(3, TimeUnit.SECONDS)
                    .readTimeout(3, TimeUnit.SECONDS)
                    .writeTimeout(3, TimeUnit.SECONDS)
                    .callTimeout(5, TimeUnit.SECONDS)
                    .build();
            return new DnsOverHttps.Builder().client(client).url(HttpUrl.get(url)).bootstrapDnsHosts(item.getHosts()).build();
        });
    }

    @NonNull
    @Override
    public List<InetAddress> lookup(@NonNull String hostname) throws UnknownHostException {
        NetProfiles.Profile p = NetProfiles.get(Util.clientId());
        hostname = get(hostname, p.hosts);
        DnsOverHttps doh = dohClient(p.doh);
        if (doh != null && !dohUnavailable) {
            try {
                return doh.lookup(hostname);
            } catch (UnknownHostException e) {
                dohUnavailable = true;
            }
        }
        return Dns.SYSTEM.lookup(hostname);
    }
}
