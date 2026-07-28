package android.net;

import java.net.URI;
import java.net.URISyntaxException;
import java.net.URLDecoder;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public final class Uri {
    private final URI value;

    private Uri(URI value) { this.value = value; }

    public static Uri parse(String value) { return new Uri(URI.create(value)); }
    public static String encode(String value) { return encode(value, null); }
    public static String encode(String value, String allow) {
        if (value == null) return null;
        String encoded = URLEncoder.encode(value, StandardCharsets.UTF_8).replace("+", "%20");
        if (allow != null) for (char ch : allow.toCharArray()) {
            String escaped = String.format("%%%02X", (int) ch);
            encoded = encoded.replace(escaped, String.valueOf(ch));
        }
        return encoded;
    }
    public static String decode(String value) { return value == null ? null : URLDecoder.decode(value, StandardCharsets.UTF_8); }

    public String getScheme() { return value.getScheme(); }
    public String getHost() { return value.getHost(); }
    public String getAuthority() { return value.getRawAuthority(); }
    public String getUserInfo() { return value.getUserInfo(); }
    public int getPort() { return value.getPort(); }
    public String getPath() { return value.getPath(); }
    public String getEncodedPath() { return value.getRawPath(); }
    public String getQuery() { return value.getQuery(); }
    public String getEncodedQuery() { return value.getRawQuery(); }
    public String getFragment() { return value.getFragment(); }
    public String getLastPathSegment() {
        String path = getPath();
        if (path == null || path.isEmpty()) return null;
        int index = path.lastIndexOf('/');
        return index < 0 ? path : path.substring(index + 1);
    }
    public List<String> getPathSegments() {
        String path = getPath();
        if (path == null || path.isEmpty()) return Collections.emptyList();
        List<String> parts = new ArrayList<>();
        for (String part : path.split("/")) if (!part.isEmpty()) parts.add(part);
        return Collections.unmodifiableList(parts);
    }
    public String getQueryParameter(String key) {
        List<String> values = getQueryParameters(key);
        return values.isEmpty() ? null : values.get(0);
    }
    public List<String> getQueryParameters(String key) {
        List<String> matches = new ArrayList<>();
        String query = value.getRawQuery();
        if (query == null) return matches;
        for (String part : query.split("&")) {
            int separator = part.indexOf('=');
            String candidate = decode(separator < 0 ? part : part.substring(0, separator));
            if (key.equals(candidate)) matches.add(decode(separator < 0 ? "" : part.substring(separator + 1)));
        }
        return Collections.unmodifiableList(matches);
    }
    public Builder buildUpon() { return new Builder(this); }
    @Override public String toString() { return value.toString(); }

    public static final class Builder {
        private String scheme, authority, path, fragment;
        private final List<String[]> parameters = new ArrayList<>();
        public Builder() {}
        private Builder(Uri uri) {
            scheme = uri.getScheme(); authority = uri.getAuthority(); path = uri.getEncodedPath(); fragment = uri.getFragment();
            String query = uri.getEncodedQuery();
            if (query != null) for (String part : query.split("&")) {
                int separator = part.indexOf('=');
                parameters.add(new String[]{part.substring(0, separator < 0 ? part.length() : separator),
                        separator < 0 ? null : part.substring(separator + 1)});
            }
        }
        public Builder scheme(String value) { scheme = value; return this; }
        public Builder authority(String value) { authority = value; return this; }
        public Builder encodedAuthority(String value) { authority = value; return this; }
        public Builder path(String value) { path = encode(value, "/"); return this; }
        public Builder encodedPath(String value) { path = value; return this; }
        public Builder appendPath(String value) { path = (path == null ? "" : path.replaceAll("/$", "")) + "/" + encode(value); return this; }
        public Builder appendEncodedPath(String value) { path = (path == null ? "" : path.replaceAll("/$", "")) + "/" + value; return this; }
        public Builder appendQueryParameter(String key, String value) { parameters.add(new String[]{encode(key), value == null ? null : encode(value)}); return this; }
        public Builder fragment(String value) { fragment = value; return this; }
        public Uri build() {
            StringBuilder query = new StringBuilder();
            for (String[] parameter : parameters) {
                if (query.length() > 0) query.append('&');
                query.append(parameter[0]);
                if (parameter[1] != null) query.append('=').append(parameter[1]);
            }
            try {
                return new Uri(new URI(scheme, authority, path, query.length() == 0 ? null : query.toString(), fragment));
            } catch (URISyntaxException error) {
                throw new IllegalArgumentException(error);
            }
        }
    }
}
