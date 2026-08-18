package com.bobo.kotv;

import android.content.Context;
import android.os.Build;
import android.util.Log;
import com.android.tools.r8.CompilationMode;
import com.android.tools.r8.D8;
import com.android.tools.r8.D8Command;
import com.android.tools.r8.OutputMode;
import com.github.catvod.utils.Path;
import dalvik.system.DexClassLoader;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Paths;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Comparator;
import java.util.Enumeration;
import java.util.List;
import java.util.Locale;
import java.util.TreeSet;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;

/**
 * 安卓同时吃两种站点 jar，互不影响桌面通用包：
 *
 * <ul>
 *   <li>TV / CatVodSpider：已含 {@code classes.dex} → 原文件只读，不跑 D8</li>
 *   <li>其它平台 JVM 瘦包：只有 {@code .class} → D8 转成含 dex 的 sealed jar</li>
 * </ul>
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
   * @return 可交给 {@link DexClassLoader} 的 jar 绝对路径
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

    if (jarHasDex(src)) {
      // 对齐 TV JarLoader.load：原文件 setReadOnly 后直接 DexClassLoader，不拷贝不重打包。
      if (!src.setReadOnly()) {
        markReadonly(src);
      }
      return src.getAbsolutePath();
    }

    File codeCache = ctx.getCodeCacheDir();
    File sealedDir = new File(codeCache, "kotv_site_jars");
    if (!sealedDir.isDirectory() && !sealedDir.mkdirs()) {
      throw new IllegalStateException("cannot mkdir " + sealedDir);
    }
    purgeLegacyDxCache(sealedDir);
    String key = md5Hex(src.getAbsolutePath() + ":" + src.length() + ":" + src.lastModified());

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

    D8Command.Builder builder =
        D8Command.builder()
            .addProgramFiles(Paths.get(src.getAbsolutePath()))
            .setMinApiLevel(minApi)
            .setMode(CompilationMode.RELEASE)
            .setOutput(Paths.get(work.getAbsolutePath()), OutputMode.DexIndexed);

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
    packDexJar(dexFiles, tmp, src);
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

  /**
   * 对齐 TV {@code new DexClassLoader(file, Path.jar(), Path.jar(), App.get().getClassLoader())}。
   *
   * <ul>
   *   <li>已有 {@code classes.dex}（TV / CatVodSpider）：只读直通，不 D8
   *   <li>PC JVM 瘦包：先 {@link #ensureSiteDexJar} D8，再同样加载
   * </ul>
   */
  public static ClassLoader createSiteClassLoader(Object context, String srcPath, ClassLoader parent)
      throws Exception {
    if (!(context instanceof Context)) {
      throw new IllegalArgumentException("createSiteClassLoader expects Context");
    }
    Context ctx = (Context) context;
    File src = new File(srcPath);
    if (!src.isFile() || src.length() == 0L) {
      throw new IllegalStateException("site jar missing: " + srcPath);
    }
    boolean hasDex = jarHasDex(src);
    File load = new File(ensureSiteDexJar(ctx, srcPath));
    if (!load.isFile() || load.length() == 0L) {
      throw new IllegalStateException("site jar not loadable: " + srcPath);
    }
    if (!load.setReadOnly()) {
      markReadonly(load);
    }
    String cachePath = Path.jar().getAbsolutePath();
    ClassLoader appParent = ctx.getClassLoader();
    if (appParent == null) {
      appParent = parent;
    }
    Log.i(
        TAG,
        "DexClassLoader file="
            + load.getName()
            + " size="
            + load.length()
            + " srcDex="
            + hasDex
            + " cache="
            + cachePath
            + " parent="
            + (appParent == null ? "null" : appParent.getClass().getName())
            + " spiders="
            + listSpiderClasses(hasDex ? src.getAbsolutePath() : load.getAbsolutePath()));
    return new DexClassLoader(load.getAbsolutePath(), cachePath, cachePath, appParent);
  }

  /** 给 CNF 诊断：jar 里实际有哪些 {@code com.github.catvod.spider.*}。 */
  public static String listSpiderClasses(String srcPath) {
    try {
      File src = new File(srcPath);
      List<byte[]> dexes = extractDexBlobs(src);
      if (dexes.isEmpty() && src.isFile()) {
        return "no-dex entries=" + zipEntryHint(src);
      }
      String names = listSpiderNames(dexes);
      return names.isEmpty() ? "dexes=" + dexes.size() + " spiders=(none)" : names;
    } catch (Throwable t) {
      return "list-failed:" + t.getMessage();
    }
  }

  private static void purgeLegacyDxCache(File sealedDir) {
    File[] legacy = sealedDir.listFiles((dir, name) -> name.endsWith("-dx.jar") || name.endsWith("-dx.jar.tmp"));
    if (legacy == null) return;
    for (File f : legacy) {
      //noinspection ResultOfMethodCallIgnored
      f.delete();
    }
  }

  private static void packDexJar(File[] dexFiles, File outJar, File srcJar) throws Exception {
    File parent = outJar.getParentFile();
    if (parent != null && !parent.isDirectory() && !parent.mkdirs()) {
      throw new IllegalStateException("cannot mkdir " + parent);
    }
    try (ZipOutputStream zos = new ZipOutputStream(new FileOutputStream(outJar))) {
      for (File dex : dexFiles) {
        writeStored(zos, dex.getName(), java.nio.file.Files.readAllBytes(dex.toPath()));
      }
      if (srcJar != null && srcJar.isFile()) {
        copyNonCodeEntries(srcJar, zos);
      }
    }
  }

  private static void copyNonCodeEntries(File srcJar, ZipOutputStream zos) throws Exception {
    try (ZipFile zf = new ZipFile(srcJar)) {
      Enumeration<? extends ZipEntry> en = zf.entries();
      while (en.hasMoreElements()) {
        ZipEntry in = en.nextElement();
        if (in.isDirectory()) continue;
        String name = in.getName();
        if (isSignature(name) || name.endsWith(".class") || isDexBasename(name)) continue;
        ZipEntry out = new ZipEntry(name);
        zos.putNextEntry(out);
        zos.write(readZip(zf, in));
        zos.closeEntry();
      }
    }
  }

  private static void writeStored(ZipOutputStream zos, String name, byte[] data) throws Exception {
    ZipEntry entry = new ZipEntry(name);
    entry.setMethod(ZipEntry.STORED);
    entry.setSize(data.length);
    entry.setCompressedSize(data.length);
    java.util.zip.CRC32 crc = new java.util.zip.CRC32();
    crc.update(data);
    entry.setCrc(crc.getValue());
    zos.putNextEntry(entry);
    zos.write(data);
    zos.closeEntry();
  }

  private static byte[] readZip(ZipFile zf, ZipEntry e) throws Exception {
    ByteArrayOutputStream bos = new ByteArrayOutputStream();
    byte[] buf = new byte[64 * 1024];
    try (InputStream in = zf.getInputStream(e)) {
      int n;
      while ((n = in.read(buf)) >= 0) {
        bos.write(buf, 0, n);
      }
    }
    return bos.toByteArray();
  }

  private static boolean isSignature(String name) {
    String n = name.toUpperCase(Locale.US);
    return n.startsWith("META-INF/")
        && (n.endsWith(".SF") || n.endsWith(".RSA") || n.endsWith(".DSA") || n.startsWith("META-INF/SIG-"));
  }

  private static boolean isDexBasename(String name) {
    String base = dexBasename(name);
    return base.startsWith("classes") && base.endsWith(".dex");
  }

  private static String dexBasename(String name) {
    int slash = Math.max(name.lastIndexOf('/'), name.lastIndexOf('\\'));
    return slash >= 0 ? name.substring(slash + 1) : name;
  }

  private static boolean jarHasDex(File jarFile) {
    try (ZipFile zf = new ZipFile(jarFile)) {
      Enumeration<? extends ZipEntry> en = zf.entries();
      while (en.hasMoreElements()) {
        ZipEntry e = en.nextElement();
        if (e.isDirectory()) continue;
        if (isDexBasename(e.getName())) return true;
      }
    } catch (Throwable ignored) {
    }
    return false;
  }

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

  private static String zipEntryHint(File jar) {
    StringBuilder sb = new StringBuilder();
    try (ZipFile zf = new ZipFile(jar)) {
      Enumeration<? extends ZipEntry> en = zf.entries();
      int n = 0;
      while (en.hasMoreElements() && n < 12) {
        ZipEntry e = en.nextElement();
        if (e.isDirectory()) continue;
        if (sb.length() > 0) sb.append(',');
        sb.append(e.getName());
        n++;
      }
    } catch (Throwable t) {
      return t.getMessage();
    }
    return sb.toString();
  }

  private static List<byte[]> extractDexBlobs(File file) {
    List<byte[]> out = new ArrayList<>();
    if (file == null || !file.isFile() || file.length() < 8L) return out;
    byte[] head = new byte[8];
    try (FileInputStream in = new FileInputStream(file)) {
      if (in.read(head) != 8) return out;
    } catch (Throwable ignored) {
      return out;
    }
    if (head[0] == 'd' && head[1] == 'e' && head[2] == 'x' && head[3] == '\n') {
      try {
        out.add(java.nio.file.Files.readAllBytes(file.toPath()));
      } catch (Throwable ignored) {
      }
      return out;
    }
    try (ZipFile zf = new ZipFile(file)) {
      List<ZipEntry> dexEntries = new ArrayList<>();
      Enumeration<? extends ZipEntry> en = zf.entries();
      while (en.hasMoreElements()) {
        ZipEntry e = en.nextElement();
        if (!e.isDirectory() && isDexBasename(e.getName())) dexEntries.add(e);
      }
      dexEntries.sort(Comparator.comparing(e -> dexBasename(e.getName())));
      for (ZipEntry e : dexEntries) {
        out.add(readZip(zf, e));
      }
    } catch (Throwable ignored) {
    }
    return out;
  }

  private static String listSpiderNames(List<byte[]> dexes) {
    TreeSet<String> names = new TreeSet<>();
    for (byte[] dex : dexes) {
      names.addAll(readDexSpiderNames(dex));
    }
    if (names.isEmpty()) return "";
    StringBuilder sb = new StringBuilder();
    int n = 0;
    for (String name : names) {
      if (n >= 40) {
        sb.append(",...");
        break;
      }
      if (sb.length() > 0) sb.append(',');
      sb.append(name);
      n++;
    }
    return sb.toString();
  }

  private static List<String> readDexSpiderNames(byte[] dex) {
    List<String> names = new ArrayList<>();
    if (dex == null || dex.length < 112) return names;
    if (dex[0] != 'd' || dex[1] != 'e' || dex[2] != 'x') return names;
    ByteBuffer buf = ByteBuffer.wrap(dex).order(ByteOrder.LITTLE_ENDIAN);
    int stringIdsSize = buf.getInt(56);
    int stringIdsOff = buf.getInt(60);
    int typeIdsOff = buf.getInt(68);
    int classDefsSize = buf.getInt(96);
    int classDefsOff = buf.getInt(100);
    String prefix = "Lcom/github/catvod/spider/";
    for (int i = 0; i < classDefsSize; i++) {
      int defOff = classDefsOff + i * 32;
      if (defOff + 4 > dex.length) break;
      int classIdx = buf.getInt(defOff);
      int typeOff = typeIdsOff + classIdx * 4;
      if (typeOff + 4 > dex.length) continue;
      int strIdx = buf.getInt(typeOff);
      String desc = readDexString(dex, stringIdsOff, stringIdsSize, strIdx);
      if (desc == null || !desc.startsWith(prefix) || !desc.endsWith(";")) continue;
      if (desc.indexOf('$') >= 0) continue;
      names.add(desc.substring(prefix.length(), desc.length() - 1));
    }
    return names;
  }

  private static String readDexString(byte[] dex, int stringIdsOff, int stringIdsSize, int strIdx) {
    if (strIdx < 0 || strIdx >= stringIdsSize) return null;
    int idOff = stringIdsOff + strIdx * 4;
    if (idOff + 4 > dex.length) return null;
    int dataOff =
        (dex[idOff] & 0xff)
            | ((dex[idOff + 1] & 0xff) << 8)
            | ((dex[idOff + 2] & 0xff) << 16)
            | ((dex[idOff + 3] & 0xff) << 24);
    if (dataOff < 0 || dataOff >= dex.length) return null;
    int[] cursor = new int[] {dataOff};
    readUleb128(dex, cursor);
    StringBuilder sb = new StringBuilder();
    while (cursor[0] < dex.length) {
      int b = dex[cursor[0]++] & 0xff;
      if (b == 0) break;
      sb.append((char) b);
    }
    return sb.toString();
  }

  private static int readUleb128(byte[] dex, int[] cursor) {
    int result = 0;
    int shift = 0;
    while (cursor[0] < dex.length) {
      int b = dex[cursor[0]++] & 0xff;
      result |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) break;
      shift += 7;
    }
    return result;
  }
}
