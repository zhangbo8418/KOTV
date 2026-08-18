package android.content;

import android.content.res.AssetManager;

import java.io.File;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/** Minimal desktop implementation of the Android Context APIs used by CatVod spiders. */
public class Context {
    public static final int MODE_PRIVATE = 0;
    public static final String CLIPBOARD_SERVICE = "clipboard";
    private static final Map<String, SharedPreferences> PREFERENCES = new ConcurrentHashMap<>();
    private final File root;

    public Context() {
        this(resolveRoot());
    }

    public Context(File root) {
        this.root = root;
        this.root.mkdirs();
    }

    public File getCacheDir() {
        return directory("cache");
    }

    public File getFilesDir() {
        return directory("files");
    }

    public AssetManager getAssets() {
        return new AssetManager(directory("assets"));
    }

    public SharedPreferences getSharedPreferences(String name, int mode) {
        return PREFERENCES.computeIfAbsent(name == null ? "" : name,
                key -> new FileSharedPreferences(directory("prefs"), key));
    }

    public Context getApplicationContext() {
        return this;
    }

    public ClassLoader getClassLoader() {
        ClassLoader cl = Context.class.getClassLoader();
        return cl != null ? cl : ClassLoader.getSystemClassLoader();
    }

    public Object getSystemService(String name) {
        if (CLIPBOARD_SERVICE.equals(name)) return new ClipboardManager();
        return null;
    }

    public String getPackageName() {
        return "com.bobo.kotv";
    }

    private File directory(String name) {
        File directory = new File(root, name);
        directory.mkdirs();
        return directory;
    }

    private static File resolveRoot() {
        String value = System.getProperty("kotv.cache.dir");
        if (value == null || value.isEmpty()) value = System.getenv("KOTV_CACHE_DIR");
        if (value == null || value.isEmpty()) value = new File(System.getProperty("user.home"), ".kotv").getPath();
        return new File(value);
    }
}
