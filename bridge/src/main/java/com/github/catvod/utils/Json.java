package com.github.catvod.utils;

import android.text.TextUtils;

import com.github.catvod.crawler.SpiderDebug;
import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import com.google.gson.JsonSyntaxException;
import com.google.gson.stream.JsonReader;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.StringReader;
import java.lang.reflect.Type;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * TV catvod Json + CatVodSpider 站点常用扩展（官方 app 源里在 utils，R8 后进 spider.merge；
 * KOTV 父优先由 bridge 提供同名 API）。
 */
public class Json {

    private static final Gson gson = new GsonBuilder().setLenient().create();

    public static Gson get() {
        return gson;
    }

    public static JsonElement parse(String json) {
        if (json == null || json.trim().isEmpty()) return new JsonObject();
        try {
            JsonReader reader = new JsonReader(new StringReader(json));
            reader.setLenient(true);
            return JsonParser.parseReader(reader);
        } catch (Throwable e) {
            try {
                return JsonParser.parseString(json);
            } catch (Throwable t) {
                return new JsonParser().parse(json);
            }
        }
    }

    public static <T> T parseSafe(String json, Type t) {
        try {
            return gson.fromJson(extractJsonObject(json), t);
        } catch (JsonSyntaxException e) {
            SpiderDebug.log("json parse error: " + e.getMessage() + "\n" + " " + json);
            return null;
        }
    }

    public static String extractJsonObject(String json) {
        if (json == null) return "";
        json = json.trim();
        if (json.isEmpty() || !json.startsWith("{")) return json;
        int depth = 0;
        boolean inString = false;
        boolean escape = false;
        for (int i = 0; i < json.length(); i++) {
            char c = json.charAt(i);
            if (inString) {
                if (escape) escape = false;
                else if (c == '\\') escape = true;
                else if (c == '"') inString = false;
                continue;
            }
            if (c == '"') {
                inString = true;
                continue;
            }
            if (c == '{') depth++;
            else if (c == '}') {
                depth--;
                if (depth == 0) return json.substring(0, i + 1);
            }
        }
        return json;
    }

    public static String toJson(Object obj) {
        return gson.toJson(obj);
    }

    public static String unwrapHtml(String body) {
        if (body == null || body.isEmpty()) return "";
        String t = body.trim();
        if (t.length() < 2 || t.charAt(0) != '"') return body;
        if (!(t.startsWith("\"<!DOCTYPE") || t.startsWith("\"<!doctype") || t.startsWith("\"<html")
                || t.startsWith("\"\\u003c") || t.contains("\\\""))) {
            return body;
        }
        try {
            String decoded = gson.fromJson(t, String.class);
            if (decoded != null && !decoded.isEmpty()) return decoded;
        } catch (Throwable ignored) {
        }
        return body;
    }

    public static JsonObject safeObject(String extend) {
        if (extend == null || extend.trim().isEmpty()) return new JsonObject();
        try {
            JsonElement el = JsonParser.parseString(extend);
            return el != null && el.isJsonObject() ? el.getAsJsonObject() : new JsonObject();
        } catch (Throwable e) {
            return new JsonObject();
        }
    }

    public static boolean isObj(String text) {
        try {
            if (TextUtils.isEmpty(text)) return false;
            new JSONObject(text);
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    public static boolean isArray(String text) {
        try {
            if (TextUtils.isEmpty(text)) return false;
            new JSONArray(text);
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    public static boolean isEmpty(JsonObject obj, String key) {
        if (!obj.has(key)) return true;
        JsonElement element = obj.get(key);
        if (element.isJsonNull()) return true;
        if (element.isJsonArray()) return element.getAsJsonArray().isEmpty();
        if (element.isJsonPrimitive() && element.getAsJsonPrimitive().isString()) return element.getAsString().trim().isEmpty();
        return true;
    }

    public static String safeString(JsonObject obj, String key) {
        try {
            return obj.getAsJsonPrimitive(key).getAsString().trim();
        } catch (Exception e) {
            return "";
        }
    }

    public static List<String> safeListString(JsonObject obj, String key) {
        List<String> result = new ArrayList<>();
        if (!obj.has(key)) return result;
        if (obj.get(key).isJsonObject()) result.add(safeString(obj, key));
        else for (JsonElement opt : obj.getAsJsonArray(key)) result.add(opt.getAsString());
        return result;
    }

    public static List<JsonElement> safeListElement(JsonObject obj, String key) {
        List<JsonElement> result = new ArrayList<>();
        if (!obj.has(key)) return result;
        if (obj.get(key).isJsonObject()) result.add(obj.get(key).getAsJsonObject());
        else for (JsonElement opt : obj.getAsJsonArray(key)) result.add(opt.getAsJsonObject());
        return result;
    }

    public static JsonObject safeObject(JsonElement element) {
        try {
            if (element == null || element.isJsonNull()) return new JsonObject();
            if (element.isJsonPrimitive()) element = parse(element.getAsJsonPrimitive().getAsString());
            return element.getAsJsonObject();
        } catch (Exception e) {
            return new JsonObject();
        }
    }

    public static Map<String, String> toMap(String json) {
        return TextUtils.isEmpty(json) ? null : toMap(parse(json));
    }

    public static Map<String, String> toMap(JsonElement element) {
        Map<String, String> map = new HashMap<>();
        JsonObject object = safeObject(element);
        for (Map.Entry<String, JsonElement> entry : object.entrySet()) {
            map.put(entry.getKey(), safeString(object, entry.getKey()));
        }
        return map;
    }
}
