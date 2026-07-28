package android.os;

/** Desktop main-loop marker used by Init. */
public final class Looper {
    private static final Looper MAIN = new Looper();

    private Looper() {
    }

    public static Looper getMainLooper() {
        return MAIN;
    }
}
