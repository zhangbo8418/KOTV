package android.os;

/** Desktop stub for spider-bridge compile; real ART uses framework Message. */
public final class Message {
    Runnable callback;
    Handler target;
    Message next;

    public Runnable getCallback() {
        return callback;
    }

    public Handler getTarget() {
        return target;
    }
}
