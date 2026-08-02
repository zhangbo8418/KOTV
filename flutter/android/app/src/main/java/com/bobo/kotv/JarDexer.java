package com.bobo.kotv;

import android.content.Context;
import android.os.Build;
import android.util.Log;
import com.android.tools.r8.CompilationMode;
import com.android.tools.r8.D8;
import com.android.tools.r8.D8Command;
import com.android.tools.r8.OutputMode;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Comparator;
import java.util.Enumeration;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;

/**
 * 站点 jar 是 PC/安卓通用的 JVM {@code .class} 包（不含 dex）。
 * Android 上用 D8（R8 发行物）转成含 {@code classes.dex} 的 sealed jar。
 *
 * <p>必须用 Java 公开静态方法 + ProGuard {@code -keep}：Kotlin {@code object} 在 release
 * 下会被 R8 收成 {@code u1.a}，导致 bridge 反射找不到 {@code ensureSiteDexJar}。
 */
public final class JarDexer {
  private static final String TAG = "KotvJarDexer";
  private static final String SEALED_SUFFIX = "-d8.jar";

  private static final String[] LIBRARY_CANDIDATES =
      new String[] {
        "/apex/com.android.art/javalib/core-oj.jar",
        "/apex/com.android.art/javalib/core-libart.jar",
        "/system/framework/core-oj.jar",
        "/system/framework/core-libart.jar",
        "/system/framework/framework.jar",
      };

  private JarDexer() {}

  /**
   * @param context 真机 {@link Context}（以 Object 接收，避开 bridge shim Context Class 不一致）
   * @param srcPath 站点 jar 绝对路径
   * @return sealed（含 dex）jar 绝对路径
   */
  public static String ensureSiteDexJar(Object context, String srcPath) throws Exception {
    if (!(context instanceof Context)) {
      throw new IllegalArgumentException(
          "ensureSiteDexJar expects android.content.Context, got "
              + (context == null ? "null" : context.getClass().getName()));
    }
    Context ctx = (Context) context;
    File src = new File(srcPath);
    if (!src.isFile() || src.length() == 0L) {
      throw new IllegalStateException("site jar missing: " + srcPath);
    }
    File codeCache = ctx.getCodeCacheDir();
    File sealedDir = new File(codeCache, "kotv_site_jars");
    if (!sealedDir.isDirectory() && !sealedDir.mkdirs()) {
      throw new IllegalStateException("cannot mkdir " + sealedDir);
    }
    purgeLegacyDxCache(sealedDir);
    String key = md5Hex(src.getAbsolutePath() + ":" + src.length() + ":" + src.lastModified());

    if (jarHasDex(src)) {
      File sealed = new File(sealedDir, key + ".jar");
      if (!sealed.isFile() || sealed.length() != src.length()) {
        sealCopy(src, sealed);
      }
      return sealed.getAbsolutePath();
    }

    File sealed = new File(sealedDir, key + SEALED_SUFFIX);
    if (sealed.isFile() && sealed.length() > 0L && jarHasDex(sealed)) {
      return sealed.getAbsolutePath();
    }

    File work = new File(sealedDir, key + "-d8-work");
    deleteRecursive(work);
    if (!work.mkdirs()) {
      throw new IllegalStateException("cannot mkdir " + work);
    }
    File tmp = new File(sealed.getAbsolutePath() + ".tmp");
    //noinspection ResultOfMethodCallIgnored
    tmp.delete();
    //noinspection ResultOfMethodCallIgnored
    sealed.delete();

    int classMajor = peekClassMajor(src);
    // 按当前设备 API desugar：同一份 Java 17 jar 在老机上会多做降级
    int minApi = Math.max(24, Build.VERSION.SDK_INT);
    Log.i(
        TAG,
        "d8 convert "
            + src.getName()
            + " classMajor="
            + classMajor
            + " minApi="
            + minApi
            + " -> "
            + sealed.getName());

    Path srcPathNio = Paths.get(src.getAbsolutePath());
    Path workPath = Paths.get(work.getAbsolutePath());
    D8Command.Builder builder =
        D8Command.builder()
            .addProgramFiles(srcPathNio)
            .setMinApiLevel(minApi)
            .setMode(CompilationMode.RELEASE)
            .setOutput(workPath, OutputMode.DexIndexed);

    int libCount = 0;
    for (String cand : LIBRARY_CANDIDATES) {
      File lib = new File(cand);
      if (lib.isFile() && lib.length() > 0L) {
        builder.addLibraryFiles(Paths.get(lib.getAbsolutePath()));
        libCount++;
      }
    }
    Log.i(TAG, "d8 library jars=" + libCount);

    try {
      D8.run(builder.build());
    } catch (Throwable t) {
      deleteRecursive(work);
      throw new IllegalStateException(
          "d8 failed for "
              + src.getName()
              + (classMajor > 0 ? " (classMajor=" + classMajor + ")" : "")
              + ": "
              + t.getMessage(),
          t);
    }

    File[] dexFiles = work.listFiles((dir, name) -> name.startsWith("classes") && name.endsWith(".dex"));
    if (dexFiles == null || dexFiles.length == 0) {
      deleteRecursive(work);
      throw new IllegalStateException("d8 produced no classes.dex for " + src.getName());
    }
    Arrays.sort(dexFiles, Comparator.comparing(File::getName));
    packDexJar(dexFiles, tmp);
    deleteRecursive(work);

    if (!tmp.isFile() || tmp.length() == 0L || !jarHasDex(tmp)) {
      //noinspection ResultOfMethodCallIgnored
      tmp.delete();
      throw new IllegalStateException("d8 sealed jar invalid for " + src.getName());
    }
    if (!tmp.renameTo(sealed)) {
      sealCopy(tmp, sealed);
      //noinspection ResultOfMethodCallIgnored
      tmp.delete();
    }
    markReadonly(sealed);
    return sealed.getAbsolutePath();
  }

  private static void purgeLegacyDxCache(File sealedDir) {
    File[] legacy = sealedDir.listFiles((dir, name) -> name.endsWith("-dx.jar") || name.endsWith("-dx.jar.tmp"));
    if (legacy == null) return;
    for (File f : legacy) {
      //noinspection ResultOfMethodCallIgnored
      f.delete();
    }
  }

  private static void packDexJar(File[] dexFiles, File outJar) throws Exception {
    File parent = outJar.getParentFile();
    if (parent != null && !parent.isDirectory() && !parent.mkdirs()) {
      throw new IllegalStateException("cannot mkdir " + parent);
    }
    try (ZipOutputStream zos = new ZipOutputStream(new FileOutputStream(outJar))) {
      byte[] buf = new byte[64 * 1024];
      for (File dex : dexFiles) {
        ZipEntry entry = new ZipEntry(dex.getName());
        entry.setMethod(ZipEntry.STORED);
        entry.setSize(dex.length());
        entry.setCompressedSize(dex.length());
        entry.setCrc(crc32(dex));
        zos.putNextEntry(entry);
        try (InputStream in = new FileInputStream(dex)) {
          int n;
          while ((n = in.read(buf)) >= 0) {
            zos.write(buf, 0, n);
          }
        }
        zos.closeEntry();
      }
    }
  }

  private static long crc32(File file) throws Exception {
    java.util.zip.CRC32 crc = new java.util.zip.CRC32();
    byte[] buf = new byte[64 * 1024];
    try (InputStream in = new FileInputStream(file)) {
      int n;
      while ((n = in.read(buf)) >= 0) {
        crc.update(buf, 0, n);
      }
    }
    return crc.getValue();
  }

  private static boolean jarHasDex(File jarFile) {
    try (ZipFile zf = new ZipFile(jarFile)) {
      Enumeration<? extends ZipEntry> en = zf.entries();
      while (en.hasMoreElements()) {
        ZipEntry e = en.nextElement();
        if (e.isDirectory()) continue;
        String n = e.getName();
        if (n.startsWith("classes") && n.endsWith(".dex")) return true;
      }
    } catch (Throwable ignored) {
    }
    return false;
  }

  /** 抽检 jar 内第一个 .class 的 major version；失败返回 0。 */
  private static int peekClassMajor(File jarFile) {
    try (ZipFile zf = new ZipFile(jarFile)) {
      Enumeration<? extends ZipEntry> en = zf.entries();
      while (en.hasMoreElements()) {
        ZipEntry e = en.nextElement();
        if (e.isDirectory() || !e.getName().endsWith(".class")) continue;
        try (InputStream in = zf.getInputStream(e)) {
          byte[] hdr = new byte[8];
          if (in.read(hdr) != 8) continue;
          return ((hdr[6] & 0xff) << 8) | (hdr[7] & 0xff);
        }
      }
    } catch (Throwable ignored) {
    }
    return 0;
  }

  private static void sealCopy(File src, File sealed) throws Exception {
    File tmp = new File(sealed.getAbsolutePath() + ".tmp");
    //noinspection ResultOfMethodCallIgnored
    tmp.delete();
    //noinspection ResultOfMethodCallIgnored
    sealed.delete();
    try (FileInputStream in = new FileInputStream(src);
        FileOutputStream out = new FileOutputStream(tmp)) {
      byte[] buf = new byte[64 * 1024];
      int n;
      while ((n = in.read(buf)) >= 0) {
        out.write(buf, 0, n);
      }
    }
    if (!tmp.renameTo(sealed)) {
      try (FileInputStream in = new FileInputStream(tmp);
          FileOutputStream out = new FileOutputStream(sealed)) {
        byte[] buf = new byte[64 * 1024];
        int n;
        while ((n = in.read(buf)) >= 0) {
          out.write(buf, 0, n);
        }
      }
      //noinspection ResultOfMethodCallIgnored
      tmp.delete();
    }
    markReadonly(sealed);
  }

  private static void deleteRecursive(File f) {
    if (f == null || !f.exists()) return;
    if (f.isDirectory()) {
      File[] kids = f.listFiles();
      if (kids != null) {
        for (File k : kids) deleteRecursive(k);
      }
    }
    //noinspection ResultOfMethodCallIgnored
    f.delete();
  }

  private static void markReadonly(File f) {
    if (f.setReadOnly()) return;
    try {
      Runtime.getRuntime().exec(new String[] {"chmod", "444", f.getAbsolutePath()}).waitFor();
    } catch (Throwable ignored) {
    }
  }

  private static String md5Hex(String s) throws Exception {
    MessageDigest md = MessageDigest.getInstance("MD5");
    byte[] dig = md.digest(s.getBytes(java.nio.charset.StandardCharsets.UTF_8));
    StringBuilder sb = new StringBuilder(dig.length * 2);
    for (byte b : dig) {
      sb.append(String.format("%02x", b));
    }
    return sb.toString();
  }
}
