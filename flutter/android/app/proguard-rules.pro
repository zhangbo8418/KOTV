# R8 / ProGuard：站点 jar 转 dex 靠反射，JarDexer 类名方法名不可混淆。
-keep class com.bobo.kotv.JarDexer {
    public static java.lang.String ensureSiteDexJar(java.lang.Object, java.lang.String);
    public static java.lang.ClassLoader createSiteClassLoader(java.lang.Object, java.lang.String, java.lang.ClassLoader);
    public static java.lang.String listSpiderClasses(java.lang.String);
}
-keepclassmembers class com.bobo.kotv.JarDexer {
    public static java.lang.String ensureSiteDexJar(java.lang.Object, java.lang.String);
    public static java.lang.ClassLoader createSiteClassLoader(java.lang.Object, java.lang.String, java.lang.ClassLoader);
    public static java.lang.String listSpiderClasses(java.lang.String);
}
-keep class com.bobo.kotv.JarLoader { *; }
# 安卓桥编进 App CL；站点 jar 链接 crawler.Spider / OkHttp 等宿主类
-keep class com.bobo.kotv.bridge.SpiderBridge { *; }
-keep class com.github.catvod.** { *; }
-keep class com.orhanobut.logger.** { *; }
-dontwarn cn.hutool.**
-dontwarn org.bouncycastle.**
-dontwarn edu.umd.cs.findbugs.**
-dontwarn org.simpleframework.xml.**
-dontwarn com.github.sardine.**
-dontwarn com.thegrizzlylabs.sardineandroid.**
-dontwarn com.hierynomus.**
-dontwarn org.slf4j.**
-dontwarn com.google.j2objc.**
-dontwarn javax.annotation.**
-dontwarn aQute.bnd.annotation.**
-dontwarn org.codehaus.mojo.animal_sniffer.**
# 运行时 D8（com.android.tools:r8）整包保留，避免被 shrink 掏空
-keep class com.android.tools.r8.** { *; }
-dontwarn com.android.tools.r8.**
-dontwarn com.android.tools.r8.internal.**
# 迅雷 SDK（对齐 TV）：JNI / 反射不可 shrink
-keep class com.xunlei.downloadlib.** { *; }
-keep class com.github.catvod.Init { *; }
-keep class com.github.catvod.utils.Path { *; }
-keep class com.github.catvod.utils.Prefers { *; }
-dontwarn com.xunlei.downloadlib.**
# TV dex jar 的 jar 内 JS：QuickJS JNI 类名 / native 不可 shrink
-keep class com.whl.quickjs.** { *; }
-keep class com.whl.quickjs.android.** { *; }
-dontwarn com.whl.quickjs.**
