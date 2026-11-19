#include "kotv_mpv_plugin.h"

#include <mpv/client.h>

#include <atomic>
#include <cmath>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

namespace {

struct KotvMpvState {
  FlMethodChannel* method = nullptr;
  FlEventChannel* events = nullptr;
  std::atomic<bool> listening{false};
  mpv_handle* mpv = nullptr;
  std::thread event_thread;
  std::atomic<bool> stop{false};
  std::string decode_mode = "auto";
  std::string hwdec;
  GtkWidget* view_widget = nullptr;
  int64_t wid = 0;
};

KotvMpvState* g_state = nullptr;

void emit_map(FlValue* map) {
  if (!g_state || !g_state->events || !g_state->listening.load()) return;
  fl_event_channel_send(g_state->events, map, nullptr, nullptr);
}

void emit_position() {
  if (!g_state || !g_state->mpv) return;
  double pos = 0, dur = 0, buf = 0, speed = 0;
  int pause = 1, cache = 0, eof = 0, idle = 0, core_idle = 0, seeking = 0;
  mpv_get_property(g_state->mpv, "time-pos", MPV_FORMAT_DOUBLE, &pos);
  mpv_get_property(g_state->mpv, "duration", MPV_FORMAT_DOUBLE, &dur);
  mpv_get_property(g_state->mpv, "demuxer-cache-duration", MPV_FORMAT_DOUBLE, &buf);
  mpv_get_property(g_state->mpv, "cache-speed", MPV_FORMAT_DOUBLE, &speed);
  mpv_get_property(g_state->mpv, "pause", MPV_FORMAT_FLAG, &pause);
  mpv_get_property(g_state->mpv, "paused-for-cache", MPV_FORMAT_FLAG, &cache);
  mpv_get_property(g_state->mpv, "eof-reached", MPV_FORMAT_FLAG, &eof);
  mpv_get_property(g_state->mpv, "idle-active", MPV_FORMAT_FLAG, &idle);
  mpv_get_property(g_state->mpv, "core-idle", MPV_FORMAT_FLAG, &core_idle);
  mpv_get_property(g_state->mpv, "seeking", MPV_FORMAT_FLAG, &seeking);
  const bool playing = pause == 0 && idle == 0 && core_idle == 0;
  const bool buffering =
      seeking != 0 || cache != 0 || (!playing && eof == 0 && pos <= 0.05);
  g_autoptr(FlValue) m = fl_value_new_map();
  fl_value_set_string_take(m, "event", fl_value_new_string("position"));
  fl_value_set_string_take(
      m, "positionMs",
      fl_value_new_int(static_cast<int64_t>((std::isfinite(pos) ? pos : 0) * 1000)));
  fl_value_set_string_take(
      m, "durationMs",
      fl_value_new_int(static_cast<int64_t>(
          std::max(0.0, (std::isfinite(dur) ? dur : 0) * 1000))));
  fl_value_set_string_take(
      m, "bufferedMs",
      fl_value_new_int(static_cast<int64_t>(std::max(
          0.0, ((std::isfinite(pos) ? pos : 0) + (std::isfinite(buf) ? buf : 0)) * 1000))));
  fl_value_set_string_take(m, "playing", fl_value_new_bool(playing));
  fl_value_set_string_take(m, "buffering", fl_value_new_bool(buffering));
  fl_value_set_string_take(
      m, "speedBps",
      fl_value_new_int(static_cast<int64_t>(std::max(0.0, std::isfinite(speed) ? speed : 0))));
  emit_map(m);
}

void apply_decode() {
  if (!g_state || !g_state->mpv) return;
  // 优先 Dart KotvMpvOpts.hwdecValue；无则按 decode 兜底。
  if (!g_state->hwdec.empty()) {
    mpv_set_property_string(g_state->mpv, "hwdec", g_state->hwdec.c_str());
    return;
  }
  if (g_state->decode_mode == "soft" || g_state->decode_mode == "no" ||
      g_state->decode_mode == "sw") {
    mpv_set_property_string(g_state->mpv, "hwdec", "no");
  } else if (g_state->decode_mode == "hard" || g_state->decode_mode == "hw") {
    mpv_set_property_string(g_state->mpv, "hwdec", "vaapi,vulkan,nvdec,cuda,vdpau");
  } else {
    mpv_set_property_string(g_state->mpv, "hwdec", "auto");
  }
}

void command(const std::vector<std::string>& args) {
  if (!g_state || !g_state->mpv || args.empty()) return;
  std::vector<const char*> c;
  for (const auto& a : args) c.push_back(a.c_str());
  c.push_back(nullptr);
  mpv_command(g_state->mpv, c.data());
}

void destroy_mpv() {
  if (!g_state) return;
  g_state->stop = true;
  if (g_state->mpv) mpv_wakeup(g_state->mpv);
  if (g_state->event_thread.joinable()) g_state->event_thread.join();
  if (g_state->mpv) {
    mpv_terminate_destroy(g_state->mpv);
    g_state->mpv = nullptr;
  }
  g_state->wid = 0;
}

bool ensure_mpv() {
  if (!g_state) return false;
  if (g_state->mpv) return true;
  g_state->mpv = mpv_create();
  if (!g_state->mpv) return false;

#ifdef GDK_WINDOWING_X11
  if (g_state->view_widget) {
    GdkWindow* gw = gtk_widget_get_window(g_state->view_widget);
    if (gw && GDK_IS_X11_WINDOW(gw)) {
      g_state->wid = static_cast<int64_t>(gdk_x11_window_get_xid(gw));
      mpv_set_option(g_state->mpv, "wid", MPV_FORMAT_INT64, &g_state->wid);
      mpv_set_option_string(g_state->mpv, "vo", "x11");
    }
  }
#endif
  if (g_state->wid == 0) {
    // Wayland / 无 X11：暂用 libmpv（可播音频并接受命令；画面嵌入待后续）。
    mpv_set_option_string(g_state->mpv, "vo", "libmpv");
    mpv_set_option_string(g_state->mpv, "gpu-context", "auto");
  }
  mpv_set_option_string(g_state->mpv, "hwdec", "auto");
  mpv_set_option_string(g_state->mpv, "hwdec-software-fallback", "yes");
  mpv_set_option_string(g_state->mpv, "keep-open", "yes");
  mpv_set_option_string(g_state->mpv, "idle", "yes");
  mpv_set_option_string(g_state->mpv, "osc", "no");
  mpv_set_option_string(g_state->mpv, "terminal", "no");
  if (mpv_initialize(g_state->mpv) < 0) {
    destroy_mpv();
    return false;
  }
  apply_decode();
  g_state->stop = false;
  g_state->event_thread = std::thread([] {
    while (g_state && !g_state->stop) {
      mpv_event* ev = mpv_wait_event(g_state->mpv, 0.05);
      if (!ev) continue;
      if (ev->event_id == MPV_EVENT_NONE) {
        emit_position();
        continue;
      }
      if (ev->event_id == MPV_EVENT_SHUTDOWN) break;
      if (ev->event_id == MPV_EVENT_FILE_LOADED ||
          ev->event_id == MPV_EVENT_PLAYBACK_RESTART) {
        int64_t w = 0, h = 0;
        mpv_get_property(g_state->mpv, "dwidth", MPV_FORMAT_INT64, &w);
        mpv_get_property(g_state->mpv, "dheight", MPV_FORMAT_INT64, &h);
        g_autoptr(FlValue) m = fl_value_new_map();
        fl_value_set_string_take(m, "event", fl_value_new_string("ready"));
        fl_value_set_string_take(m, "width", fl_value_new_int(w));
        fl_value_set_string_take(m, "height", fl_value_new_int(h));
        emit_map(m);
        emit_position();
      } else if (ev->event_id == MPV_EVENT_END_FILE) {
        auto* e = static_cast<mpv_event_end_file*>(ev->data);
        g_autoptr(FlValue) m = fl_value_new_map();
        if (e && e->reason == MPV_END_FILE_REASON_EOF) {
          fl_value_set_string_take(m, "event", fl_value_new_string("completed"));
        } else if (e && e->reason == MPV_END_FILE_REASON_ERROR) {
          fl_value_set_string_take(m, "event", fl_value_new_string("error"));
          fl_value_set_string_take(
              m, "message",
              fl_value_new_string(
                  (std::string("MPV ") + mpv_error_string(e->error)).c_str()));
        } else {
          continue;
        }
        emit_map(m);
      }
    }
  });
  return true;
}

std::string map_str(FlValue* args, const char* key, const std::string& def = "") {
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return def;
  FlValue* v = fl_value_lookup_string(args, key);
  if (!v || fl_value_get_type(v) != FL_VALUE_TYPE_STRING) return def;
  return fl_value_get_string(v);
}

void ingest_decode_args(FlValue* args) {
  if (!g_state) return;
  g_state->decode_mode = map_str(args, "decode", g_state->decode_mode);
  const std::string hw = map_str(args, "hwdec");
  if (!hw.empty()) g_state->hwdec = hw;
}

bool map_bool(FlValue* args, const char* key, bool def = false) {
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return def;
  FlValue* v = fl_value_lookup_string(args, key);
  if (!v || fl_value_get_type(v) != FL_VALUE_TYPE_BOOL) return def;
  return fl_value_get_bool(v);
}

int64_t map_int(FlValue* args, const char* key, int64_t def = 0) {
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return def;
  FlValue* v = fl_value_lookup_string(args, key);
  if (!v) return def;
  if (fl_value_get_type(v) == FL_VALUE_TYPE_INT) return fl_value_get_int(v);
  if (fl_value_get_type(v) == FL_VALUE_TYPE_FLOAT)
    return static_cast<int64_t>(fl_value_get_float(v));
  return def;
}

void method_call(FlMethodChannel*, FlMethodCall* call, gpointer) {
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);

  if (strcmp(method, "isVulkanAvailable") == 0) {
    fl_method_call_respond_success(call, fl_value_new_bool(FALSE), nullptr);
    return;
  }
  if (strcmp(method, "create") == 0) {
    ingest_decode_args(args);
    if (!ensure_mpv()) {
      fl_method_call_respond_error(call, "CREATE_FAILED", "mpv init failed", nullptr,
                                   nullptr);
      return;
    }
    apply_decode();
    g_autoptr(FlValue) out = fl_value_new_map();
    fl_value_set_string_take(out, "ok", fl_value_new_bool(TRUE));
    fl_value_set_string_take(out, "ready", fl_value_new_bool(TRUE));
    fl_method_call_respond_success(call, out, nullptr);
    return;
  }
  if (strcmp(method, "open") == 0) {
    ingest_decode_args(args);
    if (!ensure_mpv()) {
      fl_method_call_respond_error(call, "OPEN_FAILED", "mpv init failed", nullptr,
                                   nullptr);
      return;
    }
    apply_decode();
    std::string url = map_str(args, "url");
    int64_t start = map_int(args, "startAtMs");
    command({"stop"});
    if (start > 0) {
      char start_opt[64];
      snprintf(start_opt, sizeof(start_opt), "start=%.3f", start / 1000.0);
      command({"loadfile", url, "replace", start_opt});
    } else {
      command({"loadfile", url, "replace"});
    }
    command({"set", "pause", "no"});
    fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }
  if (strcmp(method, "play") == 0) {
    command({"set", "pause", "no"});
    fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }
  if (strcmp(method, "pause") == 0) {
    command({"set", "pause", "yes"});
    fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }
  if (strcmp(method, "stop") == 0) {
    command({"stop"});
    fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }
  if (strcmp(method, "dispose") == 0) {
    destroy_mpv();
    fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }
  if (strcmp(method, "seek") == 0) {
    char sec[64];
    snprintf(sec, sizeof(sec), "%.3f", map_int(args, "positionMs") / 1000.0);
    command({"seek", sec, "absolute"});
    fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }
  if (strcmp(method, "setDecode") == 0 || strcmp(method, "setOpts") == 0) {
    ingest_decode_args(args);
    apply_decode();
    fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }
  if (strcmp(method, "setVisible") == 0 || strcmp(method, "updateFrame") == 0 ||
      strcmp(method, "setVideoRect") == 0 || strcmp(method, "setAspect") == 0 ||
      strcmp(method, "setVolume") == 0 || strcmp(method, "setRate") == 0 ||
      strcmp(method, "setRenderMode") == 0 ||
      strcmp(method, "setSurfaceLayerEnabled") == 0) {
    fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }
  if (strcmp(method, "videoInfo") == 0) {
    g_autoptr(FlValue) m = fl_value_new_map();
    if (g_state->mpv) {
      char* hw = mpv_get_property_string(g_state->mpv, "hwdec");
      char* cur = mpv_get_property_string(g_state->mpv, "hwdec-current");
      char* vo = mpv_get_property_string(g_state->mpv, "current-vo");
      if (hw) {
        fl_value_set_string_take(m, "hwdec", fl_value_new_string(hw));
        mpv_free(hw);
      }
      if (cur) {
        fl_value_set_string_take(m, "hwdec-current", fl_value_new_string(cur));
        mpv_free(cur);
      }
      if (vo) {
        fl_value_set_string_take(m, "current-vo", fl_value_new_string(vo));
        mpv_free(vo);
      }
    }
    fl_method_call_respond_success(call, m, nullptr);
    return;
  }
  if (strcmp(method, "getAudioTracks") == 0 || strcmp(method, "getVideoTracks") == 0 ||
      strcmp(method, "getSubtitleTracks") == 0) {
    fl_method_call_respond_success(call, fl_value_new_string("[]"), nullptr);
    return;
  }
  fl_method_call_respond_not_implemented(call, nullptr);
}

FlMethodErrorResponse* listen_events(FlEventChannel*, FlValue*, gpointer*) {
  if (g_state) g_state->listening = true;
  return nullptr;
}

FlMethodErrorResponse* cancel_events(FlEventChannel*, FlValue*, gpointer*) {
  if (g_state) g_state->listening = false;
  return nullptr;
}

}  // namespace

void kotv_mpv_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  if (!g_state) g_state = new KotvMpvState();
  g_state->view_widget = GTK_WIDGET(fl_plugin_registrar_get_view(registrar));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_state->method = fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                                          "kotv_mpv", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_state->method, method_call, nullptr, nullptr);

  g_state->events = fl_event_channel_new(fl_plugin_registrar_get_messenger(registrar),
                                         "kotv_mpv/events", FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(g_state->events, listen_events, cancel_events, nullptr,
                                       nullptr);
}
