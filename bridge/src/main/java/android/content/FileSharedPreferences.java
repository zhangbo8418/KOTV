package android.content;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import java.util.Properties;

/**
 * 磁盘落盘的 SharedPreferences，用 XML 持久化 cookie/token 的行为。
 * 存储为 {name}.properties，值带类型前缀（s/i/l/f/b）以还原原始类型。
 */
final class FileSharedPreferences implements SharedPreferences {
    private final File file;
    private final Map<String, Object> values = Collections.synchronizedMap(new HashMap<>());

    FileSharedPreferences(File dir, String name) {
        this.file = new File(dir, (name == null || name.isEmpty() ? "default" : name) + ".properties");
        load();
    }

    private void load() {
        if (!file.exists()) return;
        Properties props = new Properties();
        try (FileInputStream in = new FileInputStream(file)) {
            props.load(in);
        } catch (Exception ignored) {
            return;
        }
        for (String key : props.stringPropertyNames()) {
            values.put(key, decode(props.getProperty(key)));
        }
    }

    private void persist() {
        Properties props = new Properties();
        synchronized (values) {
            for (Map.Entry<String, Object> entry : values.entrySet()) {
                props.setProperty(entry.getKey(), encode(entry.getValue()));
            }
        }
        try {
            File parent = file.getParentFile();
            if (parent != null) parent.mkdirs();
            try (FileOutputStream out = new FileOutputStream(file)) {
                props.store(out, "KOTV bridge prefs");
            }
        } catch (Exception ignored) {
        }
    }

    private static String encode(Object value) {
        if (value instanceof String) return "s:" + value;
        if (value instanceof Integer) return "i:" + value;
        if (value instanceof Long) return "l:" + value;
        if (value instanceof Float) return "f:" + value;
        if (value instanceof Boolean) return "b:" + value;
        return "s:" + String.valueOf(value);
    }

    private static Object decode(String raw) {
        if (raw == null || raw.length() < 2 || raw.charAt(1) != ':') return raw;
        String body = raw.substring(2);
        try {
            switch (raw.charAt(0)) {
                case 'i': return Integer.valueOf(body);
                case 'l': return Long.valueOf(body);
                case 'f': return Float.valueOf(body);
                case 'b': return Boolean.valueOf(body);
                default: return body;
            }
        } catch (Exception e) {
            return body;
        }
    }

    public Map<String, ?> getAll() { synchronized (values) { return new HashMap<>(values); } }
    public String getString(String key, String fallback) { return value(key, String.class, fallback); }
    public int getInt(String key, int fallback) { return value(key, Integer.class, fallback); }
    public long getLong(String key, long fallback) { return value(key, Long.class, fallback); }
    public float getFloat(String key, float fallback) { return value(key, Float.class, fallback); }
    public boolean getBoolean(String key, boolean fallback) { return value(key, Boolean.class, fallback); }
    public boolean contains(String key) { return values.containsKey(key); }
    public Editor edit() { return new FileEditor(); }

    private <T> T value(String key, Class<T> type, T fallback) {
        Object value = values.get(key);
        return type.isInstance(value) ? type.cast(value) : fallback;
    }

    private final class FileEditor implements Editor {
        private final Map<String, Object> updates = new HashMap<>();
        private boolean clear;
        public Editor putString(String key, String value) { return put(key, value); }
        public Editor putInt(String key, int value) { return put(key, value); }
        public Editor putLong(String key, long value) { return put(key, value); }
        public Editor putFloat(String key, float value) { return put(key, value); }
        public Editor putBoolean(String key, boolean value) { return put(key, value); }
        public Editor remove(String key) { return put(key, this); }
        public Editor clear() { clear = true; return this; }
        public boolean commit() { apply(); return true; }
        public void apply() {
            synchronized (values) {
                if (clear) values.clear();
                for (Map.Entry<String, Object> entry : updates.entrySet()) {
                    if (entry.getValue() == this) values.remove(entry.getKey());
                    else values.put(entry.getKey(), entry.getValue());
                }
            }
            persist();
        }
        private Editor put(String key, Object value) { updates.put(key, value); return this; }
    }
}
