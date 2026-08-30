package com.fongmi.android.tv.player.iso;

import java.nio.ByteBuffer;

/**
 * Stub for webhtv libplayer {@code register_iso_protocol} JNI.
 * DVD/ISO is unused on KOTV; methods exist so MPVLib.create can finish.
 */
public final class IsoSessionManager {
    private IsoSessionManager() {}

    public static long length(long handle) {
        return 0L;
    }

    public static int readAt(long handle, long position, ByteBuffer buffer, int size) {
        return -1;
    }

    public static void close(long handle) {}

    public static void prepareTrackMetadata(long handle, int title) {}
}
