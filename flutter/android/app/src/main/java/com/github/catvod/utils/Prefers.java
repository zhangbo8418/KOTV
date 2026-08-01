package com.github.catvod.utils;

import android.content.Context;
import android.content.SharedPreferences;

import com.github.catvod.Init;

/** Minimal shim for XLDownloadManager peerId persistence (no preference-ktx). */
public class Prefers {

    public static SharedPreferences getPrefers() {
        Context ctx = Init.context();
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
        } else {
            ed.putString(key, String.valueOf(obj));
        }
        ed.apply();
    }

    public static void remove(String key) {
        getPrefers().edit().remove(key).apply();
    }
}
