package androidx.collection;

import java.util.LinkedHashMap;

/** JVM equivalent sufficient for CatVod's Map API usage. */
public class ArrayMap<K, V> extends LinkedHashMap<K, V> {
    public ArrayMap() {
        super();
    }
}
