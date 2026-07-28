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

    private final ConcurrentHashMap<String, String> map;
    private DnsOverHttps doh;
    /** DoH unreachable (common when Google/CF blocked); stick to system DNS after first failure. */
    private volatile boolean dohUnavailable;

    public OkDns() {
        this.map = new ConcurrentHashMap<>();
    }

    public void setDoh(Doh item) {
        if (item.getUrl().isEmpty()) return;
        dohUnavailable = false;
        // Short timeouts: desktop networks often cannot reach public DoH; fail fast then fall back.
        OkHttpClient client = new OkHttpClient.Builder()
                .connectTimeout(3, TimeUnit.SECONDS)
                .readTimeout(3, TimeUnit.SECONDS)
                .writeTimeout(3, TimeUnit.SECONDS)
                .callTimeout(5, TimeUnit.SECONDS)
                .build();
        this.doh = new DnsOverHttps.Builder().client(client).url(HttpUrl.get(item.getUrl())).bootstrapDnsHosts(item.getHosts()).build();
    }

    public void clear() {
        map.clear();
    }

    public void addAll(List<String> hosts) {
        map.putAll(hosts.stream().filter(Objects::nonNull).map(host -> host.split("=", 2)).filter(splits -> splits.length == 2).collect(Collectors.toMap(s -> s[0].trim(), s -> s[1].trim(), (oldHost, newHost) -> newHost)));
    }

    private String get(String hostname) {
        String target = map.get(hostname);
        if (target != null) return target;
        for (Map.Entry<String, String> entry : map.entrySet()) if (Util.containOrMatch(hostname, entry.getKey())) return entry.getValue();
        return hostname;
    }

    @NonNull
    @Override
    public List<InetAddress> lookup(@NonNull String hostname) throws UnknownHostException {
        hostname = get(hostname);
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
