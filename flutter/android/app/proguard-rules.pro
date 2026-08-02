# R8 / ProGuard：站点 jar 转 dex 靠反射，JarDexer 类名方法名不可混淆。
-keep class com.bobo.kotv.JarDexer {
    public static java.lang.String ensureSiteDexJar(java.lang.Object, java.lang.String);
}
-keepclassmembers class com.bobo.kotv.JarDexer {
    public static java.lang.String ensureSiteDexJar(java.lang.Object, java.lang.String);
}
-keep class com.bobo.kotv.JarLoader { *; }
# 运行时 D8（com.android.tools:r8）整包保留，避免被 shrink 掏空
-keep class com.android.tools.r8.** { *; }
-dontwarn com.android.tools.r8.**
-dontwarn com.android.tools.r8.internal.**
