# R8 / ProGuard：站点 jar 转 dex 靠反射，JarDexer 类名方法名不可混淆。
-keep class com.bobo.kotv.JarDexer {
    public static java.lang.String ensureSiteDexJar(java.lang.Object, java.lang.String);
    public static java.lang.ClassLoader createSiteClassLoader(java.lang.Object, java.lang.String, java.lang.ClassLoader);
    public static java.lang.String listSpiderClasses(java.lang.String);
}
-keep class com.bobo.kotv.JarLoader { *; }
-keep class com.bobo.kotv.KotvApplication { *; }
-keep class com.bobo.kotv.host.UiContext { *; }
# 安卓桥编进 App CL；站点 jar 链接 crawler.Spider / OkHttp 等宿主类
-keep class com.bobo.kotv.bridge.SpiderBridge { *; }
-keep class com.github.catvod.** { *; }
-keep class com.orhanobut.logger.** { *; }
# TV dex jar 从 App CL 按原名解析 OkHttp（DexClassLoader 父优先）。
# Flutter Release 默认开 R8：未 keep 时 OkHttpClient 会被改成 p3.z，ConnectionPool 直接被删掉。
-dontwarn okhttp3.**
-dontwarn okio.**
-keep class okhttp3.** { *; }
-keep class okio.** { *; }
# PC 瘦包把 lang3/hutool/guava/codec 留给宿主；R8 改名后站点 jar 会 NoClassDefFoundError。
-keep class org.apache.commons.lang3.** { *; }
-keep class org.apache.commons.codec.** { *; }
-keep class org.apache.commons.io.** { *; }
-keep class cn.hutool.** { *; }
-keep class com.google.common.** { *; }
-dontwarn org.apache.commons.lang3.**
-dontwarn org.apache.commons.codec.**
-dontwarn com.google.common.**
# 其它常见宿主 API：站点 jar 同样按原名链接，R8 看不到 jar 内引用
-keep class org.jsoup.** { *; }
-keep class com.google.gson.** { *; }
-keep class org.json.** { *; }
# 对齐 TV：SimpleXML 注解/接口会被 sardine-android 反射访问
-keep interface org.simpleframework.xml.core.Label { public *; }
-keep class * implements org.simpleframework.xml.core.Label { public *; }
-keep interface org.simpleframework.xml.core.Parameter { public *; }
-keep class * implements org.simpleframework.xml.core.Parameter { public *; }
-keep interface org.simpleframework.xml.core.Extractor { public *; }
-keep class * implements org.simpleframework.xml.core.Extractor { public *; }
-keepclassmembers,allowobfuscation class * { @org.simpleframework.xml.Path <fields>; }
-keepclassmembers,allowobfuscation class * { @org.simpleframework.xml.Root <fields>; }
-keepclassmembers,allowobfuscation class * { @org.simpleframework.xml.Text <fields>; }
-keepclassmembers,allowobfuscation class * { @org.simpleframework.xml.Element <fields>; }
-keepclassmembers,allowobfuscation class * { @org.simpleframework.xml.Attribute <fields>; }
-keepclassmembers,allowobfuscation class * { @org.simpleframework.xml.ElementList <fields>; }
# 桥接自检和站点运行期都会碰到这些宿主 API，按 TV 规则保留原名
-keeppackagenames org.slf4j.**
-keep class org.slf4j.** { *; }
-keep class com.thegrizzlylabs.sardineandroid.** { *; }
# 对齐 TV：若后续站点 jar / 宿主能力接入 DLNA，需要 JUPnP 原名可见
-dontwarn org.jupnp.**
-keep class org.jupnp.** { *; }
-keep class javax.xml.** { *; }
# 对齐 TV：NewPipeExtractor / Rhino 相关类由宿主提供时，外部 dex jar 可能按原名链接
-keep class javax.script.** { *; }
-keep class jdk.dynalink.** { *; }
-keep class org.mozilla.javascript.* { *; }
-keep class org.mozilla.javascript.** { *; }
-keep class org.mozilla.javascript.engine.** { *; }
-keep class org.mozilla.classfile.ClassFileWriter
-keep class org.schabi.newpipe.extractor.timeago.patterns.** { *; }
-keep class org.schabi.newpipe.extractor.services.youtube.protos.** { *; }
-dontwarn org.mozilla.javascript.JavaToJSONConverters
-dontwarn org.mozilla.javascript.tools.**
-dontwarn com.google.re2j.**
-dontwarn javax.script.**
-dontwarn jdk.dynalink.**
-dontwarn java.awt.datatransfer.Transferable
-dontwarn java.beans.Introspector
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
-dontwarn com.xunlei.downloadlib.**
# TVBus / 荐片 P2P：站点 jar 与播放提取器按原名链接，JNI 不可 shrink
-keep class com.tvbus.engine.** { *; }
-dontwarn com.tvbus.engine.**
-keep class com.p2p.** { *; }
-dontwarn com.p2p.**
# TV dex jar 的 jar 内 JS：QuickJS JNI 类名 / native 不可 shrink
-keep class com.whl.quickjs.** { *; }
-keep class com.whl.quickjs.android.** { *; }
-dontwarn com.whl.quickjs.**
