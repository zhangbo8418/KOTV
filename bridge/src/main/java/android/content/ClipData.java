package android.content;

public final class ClipData {
    private final CharSequence text;

    private ClipData(CharSequence text) {
        this.text = text;
    }

    public static ClipData newPlainText(CharSequence label, CharSequence text) {
        return new ClipData(text);
    }

    public CharSequence getText() {
        return text;
    }
}
