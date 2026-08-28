package com.github.catvod.utils;

import android.os.Environment;
import android.util.Log;

import com.github.catvod.Init;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * App CL 上的宿主 Path。
 *
 * <p>迅雷 AAR 与站点 jar（父优先）都会解析到本类，因此必须覆盖 TV/bridge 的完整 ABI；
 * 不可只留 thunder 瘦接口，否则会盖住 bridge 里的 fat Path，导致
 * {@code Path.tv}/{@code read}/{@code write} 等 NoSuchMethodError。
 */
public class Path {

    private static final String TAG = "KotvPath";

    private static File mkdir(File file) {
        if (file == null || file.exists()) return file;
        //noinspection ResultOfMethodCallIgnored
        file.mkdirs();
        return file;
    }

    public static boolean exists(String path) {
        return new File(path.replace("file://", "")).exists();
    }

    public static boolean exists(File file) {
        return file != null && file.exists() && file.length() > 0;
    }

    public static File root() {
        return Environment.getExternalStorageDirectory();
    }

    public static File download() {
        return Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS);
    }

    public static File cache() {
        android.content.Context c = Init.context();
        if (c == null) {
            throw new IllegalStateException("Init.context is null; KotvApplication must call Init.set");
        }
        return c.getCacheDir();
    }

    public static File files() {
        android.content.Context c = Init.context();
        if (c == null) {
            throw new IllegalStateException("Init.context is null; KotvApplication must call Init.set");
        }
        return c.getFilesDir();
    }

    public static String rootPath() {
        return root().getAbsolutePath();
    }

    public static File tv() {
        return tvRoot(clientScope());
    }

    /** 站点凭证等：TV[/scope]/.name */
    public static File tv(String name) {
        return tv(clientScope(), name);
    }

    public static File tv(String scopeId, String name) {
        if (name == null) name = "";
        if (!name.isEmpty() && !name.startsWith(".")) name = "." + name;
        return new File(tvRoot(scopeId), name);
    }

    private static File tvRoot(String scopeId) {
        File base = mkdir(new File(root(), "TV"));
        String s = sanitizeScope(scopeId);
        if (s.isEmpty()) return base;
        return mkdir(new File(base, "s_" + s));
    }

    private static String clientScope() {
        try {
            return Util.scopeId();
        } catch (Throwable ignored) {
            return "";
        }
    }

    private static String sanitizeScope(String scopeId) {
        if (scopeId == null) return "";
        String s = scopeId.trim().replaceAll("[^a-zA-Z0-9._:-]", "_");
        if (s.length() > 64) s = s.substring(0, 64);
        return s;
    }

    /**
     * 对齐 TV {@code files/so}：摸鱼儿等仓的 .so 多线程走 {@link System#load(String)}，
     * 不要求 exec 位，高 targetSdk 也能用。
     * 潇洒哥等同目录落盘的 go 程序则需 {@code chmod+exec}；TV targetSdk 过高无法 exec，
     * KOTV 默认 targetSdk=28 专为此保留（见 app/build.gradle）。
     */
    public static File so() {
        return mkdir(new File(files(), "so"));
    }

    public static File js() {
        return mkdir(new File(cache(), "js"));
    }

    public static File py() {
        return mkdir(new File(cache(), "py"));
    }

    public static File jar() {
        return mkdir(new File(cache(), "jar"));
    }

    public static File exoCache() {
        return mkdir(new File(cache(), "exo"));
    }

    public static File mpvCache() {
        return mkdir(new File(cache(), "mpv"));
    }

    public static File mpv() {
        return mkdir(new File(tv(), "mpv"));
    }

    public static File epg() {
        return mkdir(new File(cache(), "epg"));
    }

    public static File jpa() {
        return mkdir(new File(cache(), "jpa"));
    }

    public static File thunder() {
        return mkdir(new File(cache(), "thunder"));
    }

    public static File root(String name) {
        return new File(root(), name);
    }

    public static File root(String child, String name) {
        return new File(mkdir(new File(root(), child)), name);
    }

    public static File cache(String name) {
        return new File(cache(), name);
    }

    public static File files(String name) {
        return new File(files(), name);
    }

    public static File mpv(String name) {
        return new File(mpv(), name);
    }

    public static File epg(String name) {
        return new File(epg(), name);
    }

    public static File js(String name) {
        return new File(js(), name);
    }

    public static File py(String name) {
        return new File(py(), name);
    }

    public static File jar(String name) {
        return new File(jar(), md5(name).concat(".jar"));
    }

    public static File thunder(String name) {
        return mkdir(new File(thunder(), name));
    }

    public static File local(String path) {
        path = path.replace("file:/", "");
        File file = new File(root(), path);
        return file.exists() ? file : new File(path);
    }

    public static String read(File file) {
        try {
            return new String(readToByte(file), StandardCharsets.UTF_8);
        } catch (Exception e) {
            return "";
        }
    }

    public static String read(InputStream is) {
        try {
            return new String(readToByte(is), StandardCharsets.UTF_8);
        } catch (IOException e) {
            return "";
        }
    }

    public static byte[] readToByte(File file) {
        try (FileInputStream is = new FileInputStream(file)) {
            return readToByte(is);
        } catch (IOException e) {
            return new byte[0];
        }
    }

    private static byte[] readToByte(InputStream is) throws IOException {
        try (InputStream input = is; ByteArrayOutputStream bos = new ByteArrayOutputStream()) {
            int read;
            byte[] buffer = new byte[16384];
            while ((read = input.read(buffer)) != -1) bos.write(buffer, 0, read);
            return bos.toByteArray();
        }
    }

    public static File write(File file, InputStream is) {
        try (InputStream input = is; FileOutputStream output = new FileOutputStream(create(file))) {
            int read;
            byte[] buffer = new byte[16384];
            while ((read = input.read(buffer)) != -1) output.write(buffer, 0, read);
            return file;
        } catch (IOException e) {
            return file;
        }
    }

    public static File write(File file, String data) {
        return write(file, data == null ? new byte[0] : data.getBytes(StandardCharsets.UTF_8));
    }

    public static File write(File file, byte[] data) {
        try (FileOutputStream fos = new FileOutputStream(create(file))) {
            fos.write(data);
            fos.flush();
            return file;
        } catch (IOException e) {
            return file;
        }
    }

    public static void move(File in, File out) {
        if (in.renameTo(out)) return;
        copy(in, out);
        clear(in);
    }

    public static void copy(File in, File out) {
        try {
            copy(new FileInputStream(in), out);
        } catch (IOException ignored) {
        }
    }

    public static void copy(InputStream in, File out) {
        try (InputStream input = in; FileOutputStream output = new FileOutputStream(create(out))) {
            int read;
            byte[] buffer = new byte[16384];
            while ((read = input.read(buffer)) != -1) output.write(buffer, 0, read);
        } catch (IOException ignored) {
        }
    }

    public static void sort(File[] files) {
        if (files == null) return;
        Arrays.sort(files, (o1, o2) -> {
            if (o1.isDirectory() && o2.isFile()) return -1;
            if (o1.isFile() && o2.isDirectory()) return 1;
            return o1.getName().toLowerCase().compareTo(o2.getName().toLowerCase());
        });
    }

    public static List<File> list(File dir) {
        File[] files = dir == null ? null : dir.listFiles();
        if (files != null) sort(files);
        return files == null ? new ArrayList<>() : Arrays.asList(files);
    }

    public static void clear(File dir) {
        if (dir == null) return;
        if (dir.isDirectory()) {
            for (File file : list(dir)) clear(file);
        }
        //noinspection ResultOfMethodCallIgnored
        if (dir.delete()) Log.d(TAG, "Deleted:" + dir);
    }

    public static File create(File file) {
        try {
            File parent = file.getParentFile();
            if (parent != null) mkdir(parent);
            if (file.exists()) clear(file);
            //noinspection ResultOfMethodCallIgnored
            if (file.createNewFile()) Log.d(TAG, "Create:" + file);
            //noinspection ResultOfMethodCallIgnored
            file.setReadable(true);
            //noinspection ResultOfMethodCallIgnored
            file.setWritable(true);
            //noinspection ResultOfMethodCallIgnored
            file.setExecutable(true);
            // go 多线程：chmod+exec（TV 同逻辑；KOTV 另靠 targetSdk≤28 才能 exec）。
            try {
                int code = Runtime.getRuntime()
                        .exec(new String[]{"chmod", "777", file.getAbsolutePath()})
                        .waitFor();
                if (code != 0) {
                    Log.w(TAG, "chmod exit " + code + " for " + file);
                }
            } catch (Throwable t) {
                Log.w(TAG, "chmod failed for " + file, t);
            }
            return file;
        } catch (IOException e) {
            return file;
        }
    }

    private static String md5(String src) {
        try {
            byte[] dig = MessageDigest.getInstance("MD5").digest(src.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder(dig.length * 2);
            for (byte b : dig) sb.append(String.format("%02x", b));
            return sb.toString();
        } catch (Exception e) {
            return Integer.toHexString(src.hashCode());
        }
    }
}
