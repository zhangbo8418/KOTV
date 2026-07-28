package com.orhanobut.logger;

/** Desktop stderr logger adapter. */
public final class Logger {
    private final String tag;

    private Logger(String tag) {
        this.tag = tag;
    }

    public static Logger t(String tag) {
        return new Logger(tag);
    }

    public void d(Object message) {
        System.err.println("D/" + tag + ": " + message);
    }

    public void d(String message, Object... args) {
        d(args == null || args.length == 0 ? message : String.format(message, args));
    }
}
