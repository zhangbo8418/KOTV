package android.text;

import java.util.Iterator;

public final class TextUtils {
    private TextUtils() {}

    public static boolean isEmpty(CharSequence text) {
        return text == null || text.length() == 0;
    }

    public static boolean isDigitsOnly(CharSequence text) {
        if (isEmpty(text)) return false;
        for (int i = 0; i < text.length(); i++) if (!Character.isDigit(text.charAt(i))) return false;
        return true;
    }

    public static boolean equals(CharSequence first, CharSequence second) {
        return first == second || (first != null && first.toString().contentEquals(second));
    }

    public static String join(CharSequence delimiter, Object[] tokens) {
        if (tokens == null) return "";
        StringBuilder out = new StringBuilder();
        for (Object token : tokens) {
            if (out.length() > 0) out.append(delimiter);
            out.append(token);
        }
        return out.toString();
    }

    public static String join(CharSequence delimiter, Iterable<?> tokens) {
        if (tokens == null) return "";
        Iterator<?> iterator = tokens.iterator();
        StringBuilder out = new StringBuilder();
        while (iterator.hasNext()) {
            if (out.length() > 0) out.append(delimiter);
            out.append(iterator.next());
        }
        return out.toString();
    }

    public static String[] split(String text, String expression) {
        return isEmpty(text) ? new String[0] : text.split(expression);
    }
}
