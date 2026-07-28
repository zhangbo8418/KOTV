package android.util;

import java.nio.charset.StandardCharsets;

public final class Base64 {
    public static final int DEFAULT = 0;
    public static final int NO_PADDING = 1;
    public static final int NO_WRAP = 2;
    public static final int CRLF = 4;
    public static final int URL_SAFE = 8;
    public static final int NO_CLOSE = 16;

    private Base64() {}

    public static byte[] decode(String input, int flags) {
        return decoder(flags).decode(input);
    }

    public static byte[] decode(byte[] input, int flags) {
        return decoder(flags).decode(input);
    }

    public static String encodeToString(byte[] input, int flags) {
        return encoder(flags).encodeToString(input);
    }

    public static byte[] encode(byte[] input, int flags) {
        return encoder(flags).encode(input);
    }

    private static java.util.Base64.Decoder decoder(int flags) {
        return (flags & URL_SAFE) != 0 ? java.util.Base64.getUrlDecoder() : java.util.Base64.getMimeDecoder();
    }

    private static java.util.Base64.Encoder encoder(int flags) {
        java.util.Base64.Encoder encoder;
        if ((flags & URL_SAFE) != 0) encoder = java.util.Base64.getUrlEncoder();
        else if ((flags & NO_WRAP) != 0) encoder = java.util.Base64.getEncoder();
        else encoder = java.util.Base64.getMimeEncoder(76, ((flags & CRLF) != 0 ? "\r\n" : "\n").getBytes(StandardCharsets.US_ASCII));
        return (flags & NO_PADDING) != 0 ? encoder.withoutPadding() : encoder;
    }
}
