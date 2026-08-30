package android.os;

/** Desktop main-loop marker used by Init. */
public final class Looper {
    private static final Looper MAIN = new Looper();
    private static final ThreadLocal<Looper> THREAD_LOCAL = new ThreadLocal<>();

    private final MessageQueue queue = new MessageQueue();

    private Looper() {
    }

    public static Looper getMainLooper() {
        return MAIN;
    }

    public static Looper myLooper() {
        Looper l = THREAD_LOCAL.get();
        return l != null ? l : MAIN;
    }

    public MessageQueue getQueue() {
        return queue;
    }
}
