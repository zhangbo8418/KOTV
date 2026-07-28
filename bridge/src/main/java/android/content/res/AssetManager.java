package android.content.res;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.InputStream;

/** Resolves desktop assets from the configured KOTV data directory or classpath. */
public final class AssetManager {
    private final File root;

    public AssetManager(File root) {
        this.root = root;
    }

    public InputStream open(String name) throws FileNotFoundException {
        InputStream resource = Thread.currentThread().getContextClassLoader().getResourceAsStream(name);
        if (resource != null) return resource;
        return new FileInputStream(new File(root, name));
    }
}
