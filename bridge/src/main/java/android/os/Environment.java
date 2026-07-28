package android.os;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;

public final class Environment {
    public static final String DIRECTORY_DOWNLOADS = "Downloads";

    private Environment() {}

    public static File getExternalStorageDirectory() {
        // 桌面 stub：模拟 Android 外部存储根目录。cookie 等具体路径仍由 jar 的 Path.tv(...) 决定。
        String root = System.getProperty("kotv.data.dir");
        if (root == null || root.isEmpty()) root = System.getenv("KOTV_DATA_DIR");
        // 与 Context 使用的 kotv.cache.dir 一致，避免 stub 根目录漂移
        if (root == null || root.isEmpty()) root = System.getProperty("kotv.cache.dir");
        if (root == null || root.isEmpty()) root = System.getenv("KOTV_CACHE_DIR");
        if (root == null || root.isEmpty()) root = new File(System.getProperty("user.home"), ".kotv").getPath();
        File directory = new File(root);
        directory.mkdirs();
        migrateLegacyRoot(directory);
        return directory;
    }

    public static File getExternalStoragePublicDirectory(String type) {
        File directory = new File(getExternalStorageDirectory(), type == null ? "" : type);
        directory.mkdirs();
        return directory;
    }

    /** 旧 stub 默认根 ~/.kotv 时留下的数据目录，迁到当前外部存储根（仅桌面兼容）。 */
    private static void migrateLegacyRoot(File root) {
        try {
            File legacy = new File(System.getProperty("user.home"), ".kotv" + File.separator + "TV");
            if (!legacy.isDirectory()) return;
            if (legacy.getCanonicalFile().equals(new File(root, "TV").getCanonicalFile())) return;
            File dest = new File(root, "TV");
            dest.mkdirs();
            File[] files = legacy.listFiles();
            if (files == null) return;
            for (File src : files) {
                if (!src.isFile()) continue;
                File out = new File(dest, src.getName());
                if (out.exists() && out.length() > 0) continue;
                Files.copy(src.toPath(), out.toPath(), StandardCopyOption.REPLACE_EXISTING);
            }
        } catch (IOException ignored) {
        }
    }
}
