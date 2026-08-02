package com.bobo.kotv;

import android.content.Context;
import android.util.Log;
import com.android.dx.command.dexer.Main;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.security.MessageDigest;
import java.util.Enumeration;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * 站点 jar 是 PC/安卓通用的 JVM {@code .class} 包（不含 dex）。
 * Android 上用 dalvik-dx 转成含 {@code classes.dex} 的 sealed jar。
 *
 * <p>必须用 Java 公开静态方法 + ProGuard {@code -keep}：Kotlin {@code object} 在 release
 * 下会被 R8 收成 {@code u1.a}，导致 bridge 反射找不到 {@code ensureSiteDexJar}。
 */
public final class JarDexer {
  private static final String TAG = "KotvJarDexer";

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
    String key = md5Hex(src.getAbsolutePath() + ":" + src.length() + ":" + src.lastModified());

    if (jarHasDex(src)) {
      File sealed = new File(sealedDir, key + ".jar");
      if (!sealed.isFile() || sealed.length() != src.length()) {
        sealCopy(src, sealed);
      }
      return sealed.getAbsolutePath();
    }

    File sealed = new File(sealedDir, key + "-dx.jar");
    if (sealed.isFile() && sealed.length() > 0L && jarHasDex(sealed)) {
      return sealed.getAbsolutePath();
    }

    File tmp = new File(sealed.getAbsolutePath() + ".tmp");
    //noinspection ResultOfMethodCallIgnored
    tmp.delete();
    //noinspection ResultOfMethodCallIgnored
    sealed.delete();

    Log.i(TAG, "dalvik-dx convert " + src.getName() + " -> " + sealed.getName());
    Main.Arguments args = new Main.Arguments();
    args.fileNames = new String[] {src.getAbsolutePath()};
    args.outName = tmp.getAbsolutePath();
    args.jarOutput = true;
    try {
      args.getClass().getField("multiDex").setBoolean(args, true);
    } catch (Throwable ignored) {
    }
    try {
      args.getClass().getField("coreLibrary").setBoolean(args, true);
    } catch (Throwable ignored) {
    }
    int code = Main.run(args);
    if (code != 0 || !tmp.isFile() || tmp.length() == 0L || !jarHasDex(tmp)) {
      throw new IllegalStateException("dalvik-dx failed code=" + code + " for " + src.getName());
    }
    if (!tmp.renameTo(sealed)) {
      sealCopy(tmp, sealed);
      //noinspection ResultOfMethodCallIgnored
      tmp.delete();
    }
    markReadonly(sealed);
    return sealed.getAbsolutePath();
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
