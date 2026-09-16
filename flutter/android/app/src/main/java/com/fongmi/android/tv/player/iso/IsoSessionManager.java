package com.fongmi.android.tv.player.iso;

import java.nio.ByteBuffer;

/**
 * Stub for webhtv libplayer {@code register_iso_protocol} JNI.
 *
 * MPVLib.create 会链到这些 native 符号；KOTV <b>不</b>走这套自定义 iso://。
 * 真正的 DVD/Blu-ray/ISO 播放由自编译 libmpv（dvdnav + libbluray）完成：
 * Dart 侧把路径改写成 {@code dvd://}/{@code bd://} 并设 dvd-device / bluray-device。
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
