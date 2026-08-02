package com.github.catvod;

import com.github.catvod.utils.Util;

public class Proxy {

    private static int port = -1;

    public static void set(int port) {
        Proxy.port = port;
    }

    public static int getPort() {
        return port;
    }

    public static String getUrl(boolean local) {
        return "http://" + (local ? "127.0.0.1" : Util.getIp()) + ":" + getPort() + "/proxy";
    }


    public static String getProxyUrl() {
        return getUrl(true);
    }

    /** KOTV / 社区站点 Util.notify、UI 握手用本地根地址 */
    public static String getHostPort() {
        if (port <= 0) {
            String configured = System.getProperty("kotv.proxy.port", System.getenv("KOTV_PROXY_PORT"));
            if (configured != null && !configured.isEmpty()) {
                try { port = Integer.parseInt(configured.trim()); } catch (NumberFormatException ignored) {}
            }
        }
        if (port <= 0) return "http://127.0.0.1:9978";
        return "http://127.0.0.1:" + port;
    }
}
