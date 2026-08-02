# R8 / ProGuard：站点 jar 转 dex / child-first 加载靠反射，类名方法名不可混淆。
-keep class com.bobo.kotv.JarDexer {
    public static java.lang.String ensureSiteDexJar(java.lang.Object, java.lang.String);
}
-keepclassmembers class com.bobo.kotv.JarDexer {
    public static java.lang.String ensureSiteDexJar(java.lang.Object, java.lang.String);
}
-keep class com.bobo.kotv.ChildFirstDexClassLoader {
    public static java.lang.ClassLoader create(java.lang.Object, java.lang.String, java.lang.ClassLoader);
}
-keepclassmembers class com.bobo.kotv.ChildFirstDexClassLoader {
    public static java.lang.ClassLoader create(java.lang.Object, java.lang.String, java.lang.ClassLoader);
}
-keep class com.bobo.kotv.JarLoader { *; }
