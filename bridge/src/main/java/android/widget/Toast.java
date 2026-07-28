package android.widget;

import android.content.Context;

/** Desktop notification replacement. */
public final class Toast {
    public static final int LENGTH_LONG = 1;
    private final CharSequence text;

    private Toast(CharSequence text) {
        this.text = text;
    }

    public static Toast makeText(Context context, CharSequence text, int duration) {
        return new Toast(text);
    }

    public void show() {
        System.err.println("[toast] " + text);
    }

    public void cancel() {
    }
}
