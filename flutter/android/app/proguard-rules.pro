# R8 / ProGuard：站点 jar 转 dex 靠反射调用 JarDexer，类名/方法名不可混淆。
# 曾出现 helper class=u1.a → ensureSiteDexJar missing。
-keep class com.bobo.kotv.JarDexer {
    public static java.lang.String ensureSiteDexJar(java.lang.Object, java.lang.String);
}
-keepclassmembers class com.bobo.kotv.JarDexer {
    public static java.lang.String ensureSiteDexJar(java.lang.Object, java.lang.String);
}
-keep class com.bobo.kotv.JarLoader { *; }
