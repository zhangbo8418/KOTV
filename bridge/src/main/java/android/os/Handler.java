package android.os;

import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

/** Desktop executor-backed Handler replacement. */
public class Handler {
    private static final ScheduledExecutorService EXECUTOR = Executors.newSingleThreadScheduledExecutor(r -> {
        Thread thread = new Thread(r, "catvod-main");
        thread.setDaemon(true);
        return thread;
    });

    public Handler(Looper looper) {
    }

    public boolean post(Runnable runnable) {
        EXECUTOR.execute(runnable);
        return true;
    }

    public boolean postDelayed(Runnable runnable, long delayMillis) {
        EXECUTOR.schedule(runnable, Math.max(0, delayMillis), TimeUnit.MILLISECONDS);
        return true;
    }
}
