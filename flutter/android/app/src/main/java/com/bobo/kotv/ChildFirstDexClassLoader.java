package com.bobo.kotv;

import android.content.Context;
import dalvik.system.DexClassLoader;
import java.io.File;

/**
 * 与桌面 {@code SpiderClassLoader} 对齐的 child-first Dex 加载器。
 *
 * <p>标准 {@link DexClassLoader} 是父优先：站点 jar 里的 {@code OkHttp}/{@code Util}
 * 会被 bridge 同名类盖掉。本类对非宿主 ABI 先查站点 dex。
 *
 * <p>必须放在 App ClassLoader（不能放进 bridge jar）：桌面编译环境没有 DexClassLoader。
 */
public final class ChildFirstDexClassLoader extends DexClassLoader {
  public ChildFirstDexClassLoader(
      String dexPath, String optimizedDirectory, String librarySearchPath, ClassLoader parent) {
    super(dexPath, optimizedDirectory, librarySearchPath, parent);
  }

  @Override
  protected Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
    synchronized (getClassLoadingLock(name)) {
      Class<?> loaded = findLoadedClass(name);
      if (loaded == null) {
        if (!isHostClass(name)) {
          try {
            loaded = findClass(name);
          } catch (ClassNotFoundException ignored) {
          }
        }
        if (loaded == null) {
          loaded = getParent() != null ? getParent().loadClass(name) : findClass(name);
        }
      }
      if (resolve) {
        resolveClass(loaded);
      }
      return loaded;
    }
  }

  /** 与 bridge SpiderClassLoader 白名单一致：这些必须父优先（真机/bridge ABI）。 */
  static boolean isHostClass(String name) {
    return name.startsWith("java.")
        || name.startsWith("javax.")
        || name.startsWith("jdk.")
        || name.startsWith("sun.")
        || name.startsWith("dalvik.")
        || name.startsWith("art.")
        || name.startsWith("android.")
        || name.startsWith("androidx.")
        || name.startsWith("com.android.")
        || name.equals("com.github.catvod.crawler.Spider")
        || name.equals("com.github.catvod.crawler.SpiderNull")
        || name.equals("com.github.catvod.crawler.SpiderDebug")
        || name.equals("com.github.catvod.Init")
        || name.equals("com.github.catvod.Proxy");
  }

  /**
   * 供 SpiderBridge 反射调用：创建 child-first 站点 ClassLoader。
   *
   * @param context 真机 Context（Object 签名避开 shim Class 不一致）
   * @param sealedJarPath 已含 classes.dex 的 sealed jar
   * @param parent bridge ClassLoader
   */
  public static ClassLoader create(Object context, String sealedJarPath, ClassLoader parent)
      throws Exception {
    if (!(context instanceof Context)) {
      throw new IllegalArgumentException(
          "create expects android.content.Context, got "
              + (context == null ? "null" : context.getClass().getName()));
    }
    Context ctx = (Context) context;
    File opt = new File(ctx.getCodeCacheDir(), "kotv_site_dex");
    if (!opt.isDirectory() && !opt.mkdirs()) {
      throw new IllegalStateException("cannot create dex opt dir: " + opt);
    }
    return new ChildFirstDexClassLoader(
        sealedJarPath, opt.getAbsolutePath(), opt.getAbsolutePath(), parent);
  }
}
