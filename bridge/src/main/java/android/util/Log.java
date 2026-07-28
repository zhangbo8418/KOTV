package android.util;

public final class Log {
    private Log() {}
    public static int v(String tag, String message) { return print("V", tag, message, null); }
    public static int d(String tag, String message) { return print("D", tag, message, null); }
    public static int i(String tag, String message) { return print("I", tag, message, null); }
    public static int w(String tag, String message) { return print("W", tag, message, null); }
    public static int w(String tag, String message, Throwable error) { return print("W", tag, message, error); }
    public static int e(String tag, String message) { return print("E", tag, message, null); }
    public static int e(String tag, String message, Throwable error) { return print("E", tag, message, error); }

    private static int print(String level, String tag, String message, Throwable error) {
        System.err.println(level + "/" + tag + ": " + message);
        if (error != null) error.printStackTrace(System.err);
        return 0;
    }
}
