package android.content;

public class ClipboardManager {
    private ClipData clip;

    public void setPrimaryClip(ClipData clip) {
        this.clip = clip;
    }

    public ClipData getPrimaryClip() {
        return clip;
    }
}
