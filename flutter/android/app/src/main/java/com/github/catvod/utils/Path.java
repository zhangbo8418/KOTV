package com.github.catvod.utils;

import com.github.catvod.Init;

import java.io.File;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** Minimal Path shim required by thunder XLTaskHelper. */
public class Path {

    private static File mkdir(File file) {
        if (file == null || file.exists()) return file;
        //noinspection ResultOfMethodCallIgnored
        file.mkdirs();
        return file;
    }

    public static File cache() {
        return Init.context().getCacheDir();
    }

    public static File files() {
        return Init.context().getFilesDir();
    }

    public static File files(String name) {
        return new File(files(), name);
    }

    public static File thunder() {
        return mkdir(new File(cache(), "thunder"));
    }

    public static File thunder(String name) {
        return mkdir(new File(thunder(), name));
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
        dir.delete();
    }
}
