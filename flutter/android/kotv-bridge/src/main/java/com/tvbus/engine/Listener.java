package com.tvbus.engine;

/** {@code :tvbus}：native so 回调。 */
public interface Listener {

    void onInited(String result);

    void onStart(String result);

    void onPrepared(String result);

    void onInfo(String result);

    void onStop(String result);

    void onQuit(String result);
}
