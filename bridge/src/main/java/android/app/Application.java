package android.app;

import android.content.Context;

/** Minimal desktop Application so Init(Context) casts remain valid. */
public class Application extends Context {
    public Application() {
        super();
    }
}
