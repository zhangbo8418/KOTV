package com.github.catvod.utils;

import android.content.Context;
import android.content.SharedPreferences;

import com.github.catvod.Init;

/**
 * App CL 宿主 Prefers（迅雷 AAR + 站点父优先都会命中本类）。
 * API /bridge，避免瘦 shim 盖住 bridge 实现后缺方法。
 */
public class Prefers {

    public static SharedPreferences getPrefers() {
        Context ctx = Init.context();
        if (ctx == null) {
            throw new IllegalStateException("Init.context is null; KotvApplication must call Init.set");
        }
        return ctx.getSharedPreferences("catvod_prefers", Context.MODE_PRIVATE);
    }

    public static String getString(String key) {
        return getString(key, "");
    }

    public static String getString(String key, String defaultValue) {
        try {
            return getPrefers().getString(key, defaultValue);
        } catch (Exception e) {
            return defaultValue;
        }
    }

    public static int getInt(String key) {
        return getInt(key, 0);
    }

    public static int getInt(String key, int defaultValue) {
        try {
            return getPrefers().getInt(key, defaultValue);
        } catch (Exception e) {
            return defaultValue;
        }
    }

    public static long getLong(String key) {
        return getLong(key, 0L);
    }

    public static long getLong(String key, long defaultValue) {
        try {
            return getPrefers().getLong(key, defaultValue);
        } catch (Exception e) {
            return defaultValue;
        }
    }

    public static float getFloat(String key) {
        return getFloat(key, 0f);
    }

    public static float getFloat(String key, float defaultValue) {
        try {
            return getPrefers().getFloat(key, defaultValue);
        } catch (Exception e) {
            return defaultValue;
        }
    }

    public static boolean getBoolean(String key) {
        return getBoolean(key, false);
    }

    public static boolean getBoolean(String key, boolean defaultValue) {
        try {
            return getPrefers().getBoolean(key, defaultValue);
        } catch (Exception e) {
            return defaultValue;
        }
    }

    public static void put(String key, Object obj) {
        if (obj == null) return;
        SharedPreferences.Editor ed = getPrefers().edit();
        if (obj instanceof String) {
            ed.putString(key, (String) obj);
        } else if (obj instanceof Boolean) {
            ed.putBoolean(key, (Boolean) obj);
        } else if (obj instanceof Float) {
            ed.putFloat(key, (Float) obj);
        } else if (obj instanceof Integer) {
            ed.putInt(key, (Integer) obj);
        } else if (obj instanceof Long) {
            ed.putLong(key, (Long) obj);
        } else if (obj instanceof Number) {
            Number n = (Number) obj;
            if (n.toString().contains(".")) ed.putFloat(key, n.floatValue());
            else ed.putInt(key, n.intValue());
        } else {
            ed.putString(key, String.valueOf(obj));
        }
        ed.apply();
    }

    public static void remove(String key) {
        getPrefers().edit().remove(key).apply();
    }
}
