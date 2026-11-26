#include "kotv_mpv_plugin.h"

#include <mpv/client.h>

#include "../../../native/kotv_mpv_hdr.h"
#include "../../../native/kotv_vulkan_probe.h"

#include <atomic>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

namespace {

struct SubFile {
  std::string path;
  std::string title;
  bool select = true;
};

struct KotvMpvState {
  FlMethodChannel* method = nullptr;
  FlEventChannel* events = nullptr;
  std::atomic<bool> listening{false};
  mpv_handle* mpv = nullptr;
  std::thread event_thread;
  std::atomic<bool> stop{false};
  // Dart KotvMpvOpts.hwdecValue()。
  std::string hwdec = "auto";
  // 建 mpv 时生效：开 = gpu-api 先试 Vulkan 再自动探测；关 = 不碰 Vulkan。
  bool vulkan = false;
  GtkWidget* view_widget = nullptr;
  int64_t wid = 0;
  bool visible = true;
  double hole_x = 0, hole_y = 0, hole_w = 0, hole_h = 0;
  std::chrono::steady_clock::time_point last_pos{};
  bool live = false;
  bool repeat_one = false;
  // 排好的下一集（播放列表下标 1）与切入后要挂的外挂字幕；方法线程写、事件线程读。
  std::mutex queue_mu;
  std::string queued_id;
  std::vector<SubFile> queued_subs;
};

KotvMpvState* g_state = nullptr;

gboolean send_on_main(gpointer data) {
  FlValue* map = static_cast<FlValue*>(data);
  if (g_state && g_state->events && g_state->listening.load()) {
    fl_event_channel_send(g_state->events, map, nullptr, nullptr);
  }
  fl_value_unref(map);
  return G_SOURCE_REMOVE;
}

// 事件线程也会发：GTK 通道只能在主线程用。
void emit_map(FlValue* map) {
  if (!g_state || !g_state->events || !g_state->listening.load()) return;
  g_idle_add(send_on_main, fl_value_ref(map));
}

void emit_event(const char* name) {
  g_autoptr(FlValue) m = fl_value_new_map();
  fl_value_set_string_take(m, "event", fl_value_new_string(name));
  emit_map(m);
}

std::string get_str(const std::string& name) {
  char* raw = mpv_get_property_string(g_state->mpv, name.c_str());
  if (!raw) return {};
  std::string s(raw);
  mpv_free(raw);
  return s;
}

std::string json_escape(const std::string& s) {
  std::string out;
  for (const unsigned char c : s) {
    if (c == '"' || c == '\\') {
      out += '\\';
      out += static_cast<char>(c);
    } else if (c < 0x20) {
      char buf[8];
      snprintf(buf, sizeof(buf), "\\u%04x", c);
      out += buf;
    } else {
      out += static_cast<char>(c);
    }
  }
  return out;
}

// 轨表 JSON（audio / video / sub），字段同 Windows / Android 插件。
std::string tracks_json(const std::string& type) {
  int64_t count = 0;
  mpv_get_property(g_state->mpv, "track-list/count", MPV_FORMAT_INT64, &count);
  std::string out = "[";
  for (int64_t i = 0; i < count; ++i) {
    const std::string p = "track-list/" + std::to_string(i) + "/";
    if (get_str(p + "type") != type) continue;
    std::string id = get_str(p + "id");
    if (id.empty()) id = "auto";
    if (out.size() > 1) out += ",";
    out += "{\"id\":\"" + json_escape(id) + "\",\"title\":\"" + json_escape(get_str(p + "title")) +
           "\",\"lang\":\"" + json_escape(get_str(p + "lang")) + "\",\"codec\":\"" +
           json_escape(get_str(p + "codec")) + "\"";
    int64_t w = 0, h = 0;
    mpv_get_property(g_state->mpv, (p + "demux-w").c_str(), MPV_FORMAT_INT64, &w);
    mpv_get_property(g_state->mpv, (p + "demux-h").c_str(), MPV_FORMAT_INT64, &h);
    if (w > 0 && h > 0) {
      out += ",\"width\":" + std::to_string(w) + ",\"height\":" + std::to_string(h);
    }
    out += "}";
  }
  return out + "]";
}

// 碟片导航：标题即 edition（0 起，带菜单的碟另有一项菜单 edition）、章节即 chapter。
FlValue* disc_info() {
  FlValue* m = fl_value_new_map();
  int64_t editions = 0, edition = -1, chapters = 0, chapter = -1;
  int menu_supported = 0;
  mpv_get_property(g_state->mpv, "edition-list/count", MPV_FORMAT_INT64, &editions);
  mpv_get_property(g_state->mpv, "current-edition", MPV_FORMAT_INT64, &edition);
  mpv_get_property(g_state->mpv, "chapter-list/count", MPV_FORMAT_INT64, &chapters);
  mpv_get_property(g_state->mpv, "chapter", MPV_FORMAT_INT64, &chapter);
  mpv_get_property(g_state->mpv, "disc-menu-supported", MPV_FORMAT_FLAG, &menu_supported);
  FlValue* titles = fl_value_new_list();
  // 只有一项（或 mpv 补的空 edition）没得选。
  for (int64_t i = 0; editions >= 2 && i < editions; ++i) {
    fl_value_append_take(titles, fl_value_new_string(
        get_str("edition-list/" + std::to_string(i) + "/title").c_str()));
  }
  FlValue* chapter_titles = fl_value_new_list();
  for (int64_t i = 0; i < chapters; ++i) {
    fl_value_append_take(chapter_titles, fl_value_new_string(
        get_str("chapter-list/" + std::to_string(i) + "/title").c_str()));
  }
  fl_value_set_string_take(m, "titles", titles);
  fl_value_set_string_take(m, "title", fl_value_new_int(edition));
  fl_value_set_string_take(m, "chapters", chapter_titles);
  fl_value_set_string_take(m, "chapter", fl_value_new_int(chapter));
  fl_value_set_string_take(m, "menuSupported", fl_value_new_bool(menu_supported != 0));
  return m;
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
  mpv_set_property_string(g_state->mpv, "hwdec", g_state->hwdec.c_str());
}

void command(const std::vector<std::string>& args) {
  if (!g_state || !g_state->mpv || args.empty()) return;
  std::vector<const char*> c;
  for (const auto& a : args) c.push_back(a.c_str());
  c.push_back(nullptr);
  mpv_command(g_state->mpv, c.data());
}

// 撤掉排队的下一集并恢复 keep-open=yes；原先有排队才返回 true。
bool clear_queued() {
  {
    std::lock_guard<std::mutex> lock(g_state->queue_mu);
    if (g_state->queued_id.empty()) return false;
    g_state->queued_id.clear();
    g_state->queued_subs.clear();
  }
  if (g_state->mpv) mpv_set_property_string(g_state->mpv, "keep-open", "yes");
  return true;
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
      // gpu-next 才能做杜比视界重塑；x11 仅作无 GPU 时的兜底。
      mpv_set_option_string(g_state->mpv, "vo", "gpu-next,gpu,x11");
      // gpu-api=auto 在 X11 上优先探 Vulkan；关 Vulkan 就只用 opengl。
      mpv_set_option_string(g_state->mpv, "gpu-api", g_state->vulkan ? "vulkan,auto" : "opengl");
    }
  }
#endif
  if (g_state->wid == 0) {
    // Wayland / 无 X11：暂用 libmpv（可播音频并接受命令；画面嵌入待后续）。
    mpv_set_option_string(g_state->mpv, "vo", "libmpv");
    mpv_set_option_string(g_state->mpv, "gpu-context", "auto");
  }
  mpv_set_option_string(g_state->mpv, "hwdec", g_state->hwdec.c_str());
  mpv_set_option_string(g_state->mpv, "hwdec-software-fallback", "yes");
  // HDR 基线见 native/kotv_mpv_hdr.h；无 Windows DXGI 黑位问题，不设 target-contrast。
  kotv_mpv::set_hdr_output_defaults(g_state->mpv);
  mpv_set_option_string(g_state->mpv, "keep-open", "yes");
  // 本集将完时提前打开排队的下一集（无缝换集）。
  mpv_set_option_string(g_state->mpv, "prefetch-playlist", "yes");
  mpv_set_option_string(g_state->mpv, "idle", "yes");
  mpv_set_option_string(g_state->mpv, "osc", "no");
  mpv_set_option_string(g_state->mpv, "terminal", "no");
  if (mpv_initialize(g_state->mpv) < 0) {
    destroy_mpv();
    return false;
  }
  mpv_observe_property(g_state->mpv, 0, "media-live", MPV_FORMAT_FLAG);
  mpv_observe_property(g_state->mpv, 0, "eof-reached", MPV_FORMAT_FLAG);
  mpv_observe_property(g_state->mpv, 0, "disc-menu-active", MPV_FORMAT_FLAG);
  g_state->stop = false;
  g_state->event_thread = std::thread([] {
    // 每个文件各报一次：keep-open=yes 时片尾只有 eof-reached，没有 END_FILE。
    bool completed_sent = false;
    bool skip_sent = false;
    std::vector<SubFile> pending_subs;
    auto has_queued = [] {
      std::lock_guard<std::mutex> lock(g_state->queue_mu);
      return !g_state->queued_id.empty();
    };
    auto post_completed = [&] {
      if (completed_sent) return;
      completed_sent = true;
      emit_event("completed");
    };
    while (g_state && !g_state->stop) {
      mpv_event* ev = mpv_wait_event(g_state->mpv, 0.05);
      if (!ev) continue;
      if (ev->event_id == MPV_EVENT_NONE) {
        const auto now = std::chrono::steady_clock::now();
        if (g_state->last_pos.time_since_epoch().count() == 0 ||
            now - g_state->last_pos >= std::chrono::milliseconds(300)) {
          g_state->last_pos = now;
          emit_position();
        }
        continue;
      }
      if (ev->event_id == MPV_EVENT_SHUTDOWN) break;
      if (ev->event_id == MPV_EVENT_PROPERTY_CHANGE) {
        auto* p = static_cast<mpv_event_property*>(ev->data);
        if (!p || !p->name) continue;
        const bool on = p->format == MPV_FORMAT_FLAG && p->data && *static_cast<int*>(p->data);
        if (std::strcmp(p->name, "media-live") == 0 && on) {
          g_autoptr(FlValue) m = fl_value_new_map();
          fl_value_set_string_take(m, "event", fl_value_new_string("live"));
          fl_value_set_string_take(m, "live", fl_value_new_bool(true));
          emit_map(m);
        } else if (std::strcmp(p->name, "eof-reached") == 0) {
          if (!on) {
            // 片尾后拖回去再播完要能再报一次。
            completed_sent = false;
          } else if (!has_queued()) {
            post_completed();
          } else if (!skip_sent) {
            // 有排队的下一集就前进过去。
            skip_sent = true;
            command({"playlist-next"});
            command({"set", "pause", "no"});
          }
        } else if (std::strcmp(p->name, "disc-menu-active") == 0) {
          // 非碟片时属性不可用（NONE），按无菜单报。
          g_autoptr(FlValue) m = fl_value_new_map();
          fl_value_set_string_take(m, "event", fl_value_new_string("discMenu"));
          fl_value_set_string_take(m, "active", fl_value_new_bool(on));
          emit_map(m);
        }
        continue;
      }
      if (ev->event_id == MPV_EVENT_START_FILE) {
        completed_sent = false;
        skip_sent = false;
        pending_subs.clear();
        int64_t pos = -1;
        mpv_get_property(g_state->mpv, "playlist-pos", MPV_FORMAT_INT64, &pos);
        std::string next_id;
        if (pos == 1) {
          std::lock_guard<std::mutex> lock(g_state->queue_mu);
          next_id.swap(g_state->queued_id);
          pending_subs.swap(g_state->queued_subs);
        }
        if (!next_id.empty()) {
          mpv_set_property_string(g_state->mpv, "keep-open", "yes");
          g_autoptr(FlValue) m = fl_value_new_map();
          fl_value_set_string_take(m, "event", fl_value_new_string("transition"));
          fl_value_set_string_take(m, "id", fl_value_new_string(next_id.c_str()));
          emit_map(m);
        }
        continue;
      }
      if (ev->event_id == MPV_EVENT_FILE_LOADED ||
          ev->event_id == MPV_EVENT_PLAYBACK_RESTART) {
        if (ev->event_id == MPV_EVENT_FILE_LOADED) {
          for (const auto& sub : pending_subs) {
            std::vector<std::string> cmd = {"sub-add", sub.path, sub.select ? "select" : "auto"};
            if (!sub.title.empty()) cmd.push_back(sub.title);
            command(cmd);
          }
          pending_subs.clear();
        }
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
        // 有排队时 keep-open=no，mpv 自己前进到下一项，这里不报 completed。
        if (e && e->reason == MPV_END_FILE_REASON_EOF) {
          if (!has_queued()) post_completed();
        } else if (e && e->reason == MPV_END_FILE_REASON_ERROR) {
          g_autoptr(FlValue) m = fl_value_new_map();
          fl_value_set_string_take(m, "event", fl_value_new_string("error"));
          fl_value_set_string_take(
              m, "message",
              fl_value_new_string(
                  (std::string("MPV ") + mpv_error_string(e->error)).c_str()));
          emit_map(m);
        }
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

double map_double(FlValue* args, const char* key, double def = 0) {
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return def;
  FlValue* v = fl_value_lookup_string(args, key);
  if (!v) return def;
  if (fl_value_get_type(v) == FL_VALUE_TYPE_FLOAT) return fl_value_get_float(v);
  if (fl_value_get_type(v) == FL_VALUE_TYPE_INT)
    return static_cast<double>(fl_value_get_int(v));
  return def;
}

void ingest_decode_args(FlValue* args) {
  if (!g_state) return;
  const std::string hw = map_str(args, "hwdec");
  if (!hw.empty()) g_state->hwdec = hw;
  g_state->vulkan = map_bool(args, "vulkan", g_state->vulkan) && KotvVulkanUsable();
  g_state->live = map_bool(args, "live", g_state->live);
  g_state->repeat_one = map_bool(args, "repeatOne", g_state->repeat_one);
}

// Dart 已把请求头归一成 Map<String, String>。
std::string header_fields(FlValue* args) {
  FlValue* h = args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP
                   ? fl_value_lookup_string(args, "headers")
                   : nullptr;
  std::string out;
  if (!h || fl_value_get_type(h) != FL_VALUE_TYPE_MAP) return out;
  for (size_t i = 0; i < fl_value_get_length(h); ++i) {
    FlValue* k = fl_value_get_map_key(h, i);
    FlValue* v = fl_value_get_map_value(h, i);
    if (fl_value_get_type(k) != FL_VALUE_TYPE_STRING || fl_value_get_type(v) != FL_VALUE_TYPE_STRING) {
      continue;
    }
    if (!out.empty()) out += ",";
    // mpv 的字符串列表以逗号分隔，值里的逗号（如 UA 的 "KHTML, like Gecko"）要转义。
    std::string field = std::string(fl_value_get_string(k)) + ": " + fl_value_get_string(v);
    for (size_t p = 0; (p = field.find(',', p)) != std::string::npos; p += 2) field.insert(p, "\\");
    out += field;
  }
  return out;
}

std::vector<SubFile> sub_files(FlValue* args) {
  std::vector<SubFile> out;
  FlValue* list = args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP
                      ? fl_value_lookup_string(args, "subs")
                      : nullptr;
  if (!list || fl_value_get_type(list) != FL_VALUE_TYPE_LIST) return out;
  for (size_t i = 0; i < fl_value_get_length(list); ++i) {
    FlValue* sub = fl_value_get_list_value(list, i);
    const std::string path = map_str(sub, "path");
    if (!path.empty()) out.push_back({path, map_str(sub, "title"), map_bool(sub, "select", true)});
  }
  return out;
}

void method_call(FlMethodChannel*, FlMethodCall* call, gpointer) {
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);

  if (strcmp(method, "isVulkanAvailable") == 0) {
    fl_method_call_respond_success(call, fl_value_new_bool(KotvVulkanUsable()), nullptr);
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
    // loadfile replace 清掉整个播放列表，排好的下一集随之作废。
    clear_queued();
    mpv_set_property_string(g_state->mpv, "http-header-fields", header_fields(args).c_str());
    std::string url = map_str(args, "url");
    int64_t start = map_int(args, "startAtMs");
    // replace 即可换片；勿 stop（打断无缝换集）。选项是第 4 个参数，第 3 个是插入位置。
    if (start > 0) {
      char start_opt[64];
      snprintf(start_opt, sizeof(start_opt), "start=%.3f", start / 1000.0);
      command({"loadfile", url, "replace", "-1", start_opt});
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
    clear_queued();
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
  if (strcmp(method, "setVisible") == 0) {
    // X11 wid 绑在 Flutter 视口上，无独立子窗可藏；记下状态供后续 VO 使用。
    if (g_state) g_state->visible = map_bool(args, "visible", true);
    fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }
  if (strcmp(method, "updateFrame") == 0 || strcmp(method, "setVideoRect") == 0) {
    // 记录洞矩形（与 Win 通道语义一致）。当前 X11 整窗 wid 无法裁切子矩形。
    if (g_state) {
      g_state->hole_x = map_double(args, "x");
      g_state->hole_y = map_double(args, "y");
      g_state->hole_w = map_double(args, "w", map_double(args, "width"));
      g_state->hole_h = map_double(args, "h", map_double(args, "height"));
    }
    fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }
  if (strcmp(method, "setVolume") == 0) {
    if (g_state && g_state->mpv) {
      double v = 100;
      if (args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
        FlValue* raw = fl_value_lookup_string(args, "volume");
        if (raw && fl_value_get_type(raw) == FL_VALUE_TYPE_FLOAT) {
          v = fl_value_get_float(raw);
        } else if (raw && fl_value_get_type(raw) == FL_VALUE_TYPE_INT) {
          v = static_cast<double>(fl_value_get_int(raw));
        }
      }
      if (v < 0) v = 0;
      if (v > 100) v = 100;
      mpv_set_property(g_state->mpv, "volume", MPV_FORMAT_DOUBLE, &v);
    }
    fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }
  if (strcmp(method, "setRate") == 0) {
    if (g_state && g_state->mpv) {
      double r = 1;
      if (args && fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
        FlValue* raw = fl_value_lookup_string(args, "rate");
        if (raw && fl_value_get_type(raw) == FL_VALUE_TYPE_FLOAT) {
          r = fl_value_get_float(raw);
        } else if (raw && fl_value_get_type(raw) == FL_VALUE_TYPE_INT) {
          r = static_cast<double>(fl_value_get_int(raw));
        }
      }
      if (r < 0.25) r = 0.25;
      if (r > 4.0) r = 4.0;
      mpv_set_property(g_state->mpv, "speed", MPV_FORMAT_DOUBLE, &r);
    }
    fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }
  if (strcmp(method, "setAspect") == 0 || strcmp(method, "setRenderMode") == 0 ||
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
    const char* type = strcmp(method, "getAudioTracks") == 0   ? "audio"
                       : strcmp(method, "getVideoTracks") == 0 ? "video"
                                                               : "sub";
    const std::string json = g_state->mpv ? tracks_json(type) : "[]";
    fl_method_call_respond_success(call, fl_value_new_string(json.c_str()), nullptr);
    return;
  }
  if (strcmp(method, "setAudioTrack") == 0 || strcmp(method, "setVideoTrack") == 0 ||
      strcmp(method, "setSubtitleTrack") == 0 || strcmp(method, "setSecondarySubtitleTrack") == 0) {
    const char* prop = strcmp(method, "setAudioTrack") == 0      ? "aid"
                       : strcmp(method, "setVideoTrack") == 0    ? "vid"
                       : strcmp(method, "setSubtitleTrack") == 0 ? "sid"
                                                                 : "secondary-sid";
    // 与 Dart 同口径：字幕空 id = 关闭，音视频空 id = 自动。
    std::string id = map_str(args, "id");
    std::string key = id;
    for (auto& ch : key) ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    const bool sub = strcmp(prop, "sid") == 0 || strcmp(prop, "secondary-sid") == 0;
    if (key == "off" || key == "none" || (key.empty() && sub)) id = "no";
    if (key.empty() && !sub) id = "auto";
    command({"set", prop, id});
    fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }
  if (strcmp(method, "addSubtitle") == 0) {
    const std::string path = map_str(args, "path");
    if (!path.empty()) {
      std::vector<std::string> cmd = {"sub-add", path, map_bool(args, "select", true) ? "select" : "auto"};
      const std::string title = map_str(args, "title");
      if (!title.empty()) cmd.push_back(title);
      command(cmd);
    }
    fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }
  if (strcmp(method, "setRepeatOne") == 0) {
    g_state->repeat_one = map_bool(args, "on");
    command({"set", "loop-file", g_state->repeat_one ? "inf" : "no"});
    fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }
  // 无缝换集，契约同 Windows：下一集追加到播放列表下标 1，keep-open=no 让片尾自然前进。
  if (strcmp(method, "queueNext") == 0) {
    const std::string id = map_str(args, "id");
    const std::string url = map_str(args, "url");
    if (!g_state->mpv || g_state->live || g_state->repeat_one || id.empty() || url.empty()) {
      fl_method_call_respond_success(call, fl_value_new_bool(FALSE), nullptr);
      return;
    }
    {
      std::lock_guard<std::mutex> lock(g_state->queue_mu);
      g_state->queued_id = id;
      g_state->queued_subs = sub_files(args);
    }
    // 只留正在播的一项，新排的总在下标 1。
    command({"playlist-clear"});
    const int64_t start = map_int(args, "startAtMs");
    if (start > 0) {
      char start_opt[64];
      snprintf(start_opt, sizeof(start_opt), "start=%.3f", start / 1000.0);
      command({"loadfile", url, "append", "-1", start_opt});
    } else {
      command({"loadfile", url, "append"});
    }
    mpv_set_property_string(g_state->mpv, "keep-open", "no");
    fl_method_call_respond_success(call, fl_value_new_bool(TRUE), nullptr);
    return;
  }
  if (strcmp(method, "clearNext") == 0) {
    if (clear_queued()) command({"playlist-clear"});
    fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }
  if (strcmp(method, "skipToNext") == 0) {
    bool queued = false;
    {
      std::lock_guard<std::mutex> lock(g_state->queue_mu);
      queued = !g_state->queued_id.empty();
    }
    if (queued) {
      command({"playlist-next"});
      command({"set", "pause", "no"});
    }
    fl_method_call_respond_success(call, fl_value_new_bool(queued && g_state->mpv), nullptr);
    return;
  }
  if (strcmp(method, "discInfo") == 0) {
    g_autoptr(FlValue) info = g_state->mpv ? disc_info() : fl_value_new_map();
    fl_method_call_respond_success(call, info, nullptr);
    return;
  }
  if (strcmp(method, "setDiscTitle") == 0 || strcmp(method, "setDiscChapter") == 0) {
    const int64_t index = map_int(args, "index", -1);
    if (index >= 0) {
      command({"set", strcmp(method, "setDiscTitle") == 0 ? "edition" : "chapter",
               std::to_string(index)});
    }
    fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }
  if (strcmp(method, "discNav") == 0) {
    const std::string action = map_str(args, "action");
    FlValue* x = args ? fl_value_lookup_string(args, "x") : nullptr;
    FlValue* y = args ? fl_value_lookup_string(args, "y") : nullptr;
    if (!action.empty()) {
      if (x && y) {
        command({"discnav", action, std::to_string(map_double(args, "x")),
                 std::to_string(map_double(args, "y"))});
      } else {
        command({"discnav", action});
      }
    }
    fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }
  fl_method_call_respond_not_implemented(call, nullptr);
}

FlMethodErrorResponse* listen_events(FlEventChannel*, FlValue*, gpointer) {
  if (g_state) g_state->listening = true;
  return nullptr;
}

FlMethodErrorResponse* cancel_events(FlEventChannel*, FlValue*, gpointer) {
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
