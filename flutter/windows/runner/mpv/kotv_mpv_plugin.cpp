#include "kotv_mpv_plugin.h"

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <mpv/client.h>

#include <algorithm>
#include <cctype>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

// 线程模型（Win7 起播卡死的根因是跨线程等待）：
// - mpv 的 VO 线程会往视频 HWND（UI 线程所有）发同步消息，所以 UI 线程绝不能同步等 mpv。
// - 后台线程绝不碰 HWND / EventSink，只把事件投进 Bridge 队列，再 PostMessage 回 UI 线程。
// - 每个 mpv 实例独立（MpvCore），dispose 交给唯一的销毁线程串行处理；新实例不等旧实例的锁。
constexpr UINT kMsgDrain = WM_APP + 0x31;
constexpr UINT kMsgDestroyHwnd = WM_APP + 0x32;
constexpr wchar_t kBridgeClass[] = L"KotvMpvBridge";
constexpr auto kTeardownWait = std::chrono::milliseconds(1500);

std::string ArgString(const EncodableMap* m, const char* key, const std::string& def = "") {
  if (!m) return def;
  auto it = m->find(EncodableValue(key));
  if (it == m->end()) return def;
  if (const auto* s = std::get_if<std::string>(&it->second)) return *s;
  return def;
}

bool HasArg(const EncodableMap* m, const char* key) {
  if (!m) return false;
  auto it = m->find(EncodableValue(key));
  return it != m->end() && !std::holds_alternative<std::monostate>(it->second);
}

bool ArgBool(const EncodableMap* m, const char* key, bool def = false) {
  if (!m) return def;
  auto it = m->find(EncodableValue(key));
  if (it == m->end()) return def;
  if (const auto* b = std::get_if<bool>(&it->second)) return *b;
  return def;
}

int64_t ArgInt64(const EncodableMap* m, const char* key, int64_t def = 0) {
  if (!m) return def;
  auto it = m->find(EncodableValue(key));
  if (it == m->end()) return def;
  if (const auto* i = std::get_if<int32_t>(&it->second)) return *i;
  if (const auto* i = std::get_if<int64_t>(&it->second)) return *i;
  if (const auto* d = std::get_if<double>(&it->second)) return static_cast<int64_t>(*d);
  return def;
}

double ArgDouble(const EncodableMap* m, const char* key, double def = 0) {
  if (!m) return def;
  auto it = m->find(EncodableValue(key));
  if (it == m->end()) return def;
  if (const auto* d = std::get_if<double>(&it->second)) return *d;
  if (const auto* i = std::get_if<int32_t>(&it->second)) return *i;
  if (const auto* i = std::get_if<int64_t>(&it->second)) return static_cast<double>(*i);
  return def;
}

std::string FmtNum(double v) {
  char buf[64];
  snprintf(buf, sizeof(buf), "%g", v);
  return buf;
}

std::string JsonEscape(const std::string& s) {
  std::string out;
  out.reserve(s.size() + 2);
  for (char c : s) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (static_cast<unsigned char>(c) < 0x20) {
          char b[8];
          snprintf(b, sizeof(b), "\\u%04x", c);
          out += b;
        } else {
          out += c;
        }
    }
  }
  return out;
}

// 与 Android KotvSubtitleColor.applySubtitleOpacity 同语义：#RRGGBB / #AARRGGBB 的 alpha 乘不透明度。
std::string ApplySubtitleOpacity(const std::string& raw, double pct) {
  std::string s = raw;
  if (!s.empty() && s[0] == '#') s = s.substr(1);
  if (s.size() != 6 && s.size() != 8) return raw;
  unsigned long v = 0;
  try {
    v = std::stoul(s, nullptr, 16);
  } catch (...) {
    return raw;
  }
  const unsigned long a0 = s.size() == 8 ? (v >> 24) & 0xFF : 0xFF;
  const unsigned long rgb = v & 0xFFFFFF;
  const int a = std::clamp(static_cast<int>(a0 * std::clamp(pct, 0.0, 100.0) / 100.0), 0, 255);
  char buf[16];
  snprintf(buf, sizeof(buf), "#%02X%06lX", a, rgb);
  return buf;
}

// mpv.conf 文本：与 macOS KotvMpvOptsParser 相同的托管键过滤。
std::vector<std::pair<std::string, std::string>> ParseConf(const std::string& text) {
  static const char* kManaged[] = {"vo", "wid", "gpu-api", "gpu-context", "hwdec",
                                   "demuxer-dovi-profile7", "cache", "cache-on-disk",
                                   "cache-pause", "cache-pause-initial"};
  std::vector<std::pair<std::string, std::string>> out;
  size_t pos = 0;
  auto trim = [](std::string v) {
    const auto b = v.find_first_not_of(" \t\r");
    if (b == std::string::npos) return std::string();
    const auto e = v.find_last_not_of(" \t\r");
    return v.substr(b, e - b + 1);
  };
  while (pos <= text.size()) {
    auto nl = text.find('\n', pos);
    if (nl == std::string::npos) nl = text.size();
    std::string line = trim(text.substr(pos, nl - pos));
    pos = nl + 1;
    if (line.empty() || line[0] == '#') continue;
    const auto hash = line.find('#');
    if (hash != std::string::npos) line = trim(line.substr(0, hash));
    if (line.empty()) continue;
    std::string key, value;
    const auto eq = line.find('=');
    const auto sp = line.find_first_of(" \t");
    if (eq != std::string::npos) {
      key = trim(line.substr(0, eq));
      value = trim(line.substr(eq + 1));
    } else if (sp != std::string::npos) {
      key = trim(line.substr(0, sp));
      value = trim(line.substr(sp + 1));
    } else {
      key = line;
      value = "yes";
    }
    const std::string base = key.rfind("no-", 0) == 0 ? key.substr(3) : key;
    bool managed = false;
    for (const char* m : kManaged) {
      if (base == m || key == m) managed = true;
    }
    if (!managed) out.emplace_back(key, value);
  }
  return out;
}

// 后台线程 → UI 线程的投递物。
struct Posted {
  enum Kind { kEvent, kShowVideo, kHideVideo } kind = kEvent;
  uint64_t core_id = 0;
  EncodableMap map;
};

// 跨线程共享：消息窗、事件队列、销毁队列。后台线程只持有 Bridge，不持有插件指针。
struct MpvCore;
struct Bridge {
  std::atomic<HWND> msg_hwnd{nullptr};
  std::mutex q_mu;
  std::deque<Posted> queue;

  std::mutex td_mu;
  std::condition_variable td_cv;
  std::deque<std::shared_ptr<MpvCore>> td_queue;
  int td_busy = 0;  // 队列中 + 正在销毁的实例数
  bool td_quit = false;
  bool td_started = false;

  void Post(Posted p) {
    {
      std::lock_guard<std::mutex> lock(q_mu);
      queue.push_back(std::move(p));
    }
    HWND h = msg_hwnd.load();
    if (h) PostMessageW(h, kMsgDrain, 0, 0);
  }

  // 新实例初始化前调用（后台线程）：最多等 kTeardownWait，避免 Win7 DXVA 会话被旧实例占着。
  void WaitTeardownIdle() {
    std::unique_lock<std::mutex> lock(td_mu);
    td_cv.wait_for(lock, kTeardownWait, [this] { return td_busy == 0; });
  }
};

struct OpenParams {
  std::string url;
  int64_t start_ms = 0;
  std::string headers;
  std::map<std::string, std::string> props;
};

struct MpvCore {
  uint64_t id = 0;
  HWND hwnd = nullptr;  // UI 线程创建/销毁
  std::atomic<mpv_handle*> mpv{nullptr};
  std::mutex mu;  // 串行化 init / open / teardown
  std::atomic<bool> disposed{false};
  std::atomic<bool> stop_events{false};
  std::atomic<uint64_t> open_gen{0};
  std::thread event_thread;

  std::mutex info_mu;
  EncodableMap info;
  std::string tracks_audio = "[]";
  std::string tracks_video = "[]";
  std::string tracks_sub = "[]";
};

// 会话级选项（UI 线程维护，快照后交给后台）。
struct SessionOpts {
  std::string decode_mode = "auto";
  std::string hwdec;
  bool direct = false;
  std::string conf;
  bool disk_cache = false;
  bool live = false;
  int dovi_policy = 0;
  std::string volume;
  std::string speed;
  std::string aspect = "default";
  bool repeat_one = false;
  std::string audio_delay;
  std::string sub_delay;
  // 均衡器（eq*/af/vf/sub-scale）：与 Android applyEqualizer 同口径。
  int eq_brightness = 0, eq_contrast = 0, eq_saturation = 0, eq_gamma = 0, eq_hue = 0;
  bool has_eq = false;
  std::string audio_af;
  bool has_af = false;
  std::string video_vf;
  bool has_vf = false;
  std::string sub_scale;
};

void SetProp(mpv_handle* m, const char* name, const std::string& v) {
  if (!m) return;
  const char* s = v.c_str();
  mpv_set_property_async(m, 0, name, MPV_FORMAT_STRING, const_cast<char**>(&s));
}

void CommandAsync(mpv_handle* m, const std::vector<std::string>& args) {
  if (!m || args.empty()) return;
  std::vector<const char*> c;
  c.reserve(args.size() + 1);
  for (const auto& a : args) c.push_back(a.c_str());
  c.push_back(nullptr);
  mpv_command_async(m, 0, c.data());
}

void CommandSync(mpv_handle* m, const std::vector<std::string>& args) {
  if (!m || args.empty()) return;
  std::vector<const char*> c;
  c.reserve(args.size() + 1);
  for (const auto& a : args) c.push_back(a.c_str());
  c.push_back(nullptr);
  mpv_command(m, c.data());
}

std::string ResolveHwdec(const SessionOpts& o) {
  if (!o.hwdec.empty()) return o.hwdec;
  if (o.decode_mode == "soft" || o.decode_mode == "no" || o.decode_mode == "sw") return "no";
  if (o.direct) return "dxva2";
  return "auto";
}

// 与 Android applyAspectMode 同映射。
void ApplyAspect(mpv_handle* m, const std::string& mode) {
  if (mode == "fill") {
    SetProp(m, "keepaspect", "no");
    SetProp(m, "panscan", "0");
    SetProp(m, "video-aspect-override", "no");
  } else if (mode == "zoom") {
    SetProp(m, "keepaspect", "yes");
    SetProp(m, "panscan", "1.0");
    SetProp(m, "video-aspect-override", "no");
  } else if (mode == "16:9" || mode == "4:3") {
    SetProp(m, "keepaspect", "yes");
    SetProp(m, "panscan", "0");
    SetProp(m, "video-aspect-override", mode);
  } else {
    SetProp(m, "keepaspect", "yes");
    SetProp(m, "panscan", "0");
    SetProp(m, "video-aspect-override", "no");
  }
}

void ApplyEqualizer(mpv_handle* m, const SessionOpts& o) {
  if (o.has_eq) {
    SetProp(m, "brightness", std::to_string(o.eq_brightness));
    SetProp(m, "contrast", std::to_string(o.eq_contrast));
    SetProp(m, "saturation", std::to_string(o.eq_saturation));
    SetProp(m, "gamma", std::to_string(o.eq_gamma));
    SetProp(m, "hue", std::to_string(o.eq_hue));
  }
  if (o.has_vf) SetProp(m, "vf", o.video_vf);
  if (o.has_af) SetProp(m, "af", o.audio_af);
  if (!o.sub_scale.empty()) SetProp(m, "sub-scale", o.sub_scale);
}

// 运行期会话选项（hwdec / dovi / cache / conf），与 macOS applySessionOpts 同口径。
void ApplySession(mpv_handle* m, const SessionOpts& o) {
  SetProp(m, "hwdec", ResolveHwdec(o));
  SetProp(m, "demuxer-dovi-profile7",
          o.dovi_policy == 2 ? "no" : (o.dovi_policy == 1 ? "yes" : "auto"));
  if (o.live || !o.disk_cache) {
    SetProp(m, "cache", "no");
    SetProp(m, "cache-pause", "no");
    SetProp(m, "cache-pause-initial", "no");
  } else {
    SetProp(m, "cache", "yes");
  }
  for (const auto& kv : ParseConf(o.conf)) SetProp(m, kv.first.c_str(), kv.second);
  if (!o.volume.empty()) SetProp(m, "volume", o.volume);
  if (!o.speed.empty()) SetProp(m, "speed", o.speed);
  SetProp(m, "loop-file", o.repeat_one ? "inf" : "no");
  if (!o.audio_delay.empty()) SetProp(m, "audio-delay", o.audio_delay);
  if (!o.sub_delay.empty()) SetProp(m, "sub-delay", o.sub_delay);
  ApplyAspect(m, o.aspect);
  ApplyEqualizer(m, o);
}

std::string GetStr(mpv_handle* m, const char* name) {
  char* raw = mpv_get_property_string(m, name);
  if (!raw) return {};
  std::string s(raw);
  mpv_free(raw);
  return s;
}

void RefreshTrackCache(MpvCore* core, mpv_handle* m) {
  int64_t count = 0;
  mpv_get_property(m, "track-list/count", MPV_FORMAT_INT64, &count);
  std::string a = "[", v = "[", s = "[";
  for (int64_t i = 0; i < count; ++i) {
    const std::string p = "track-list/" + std::to_string(i) + "/";
    const std::string type = GetStr(m, (p + "type").c_str());
    std::string* dst = type == "audio" ? &a : type == "video" ? &v : type == "sub" ? &s : nullptr;
    if (!dst) continue;
    int64_t w = 0, h = 0;
    mpv_get_property(m, (p + "demux-w").c_str(), MPV_FORMAT_INT64, &w);
    mpv_get_property(m, (p + "demux-h").c_str(), MPV_FORMAT_INT64, &h);
    std::string id = GetStr(m, (p + "id").c_str());
    if (id.empty()) id = "auto";
    std::string obj = "{\"id\":\"" + JsonEscape(id) + "\",\"title\":\"" +
                      JsonEscape(GetStr(m, (p + "title").c_str())) + "\",\"lang\":\"" +
                      JsonEscape(GetStr(m, (p + "lang").c_str())) + "\",\"codec\":\"" +
                      JsonEscape(GetStr(m, (p + "codec").c_str())) + "\"";
    if (w > 0 && h > 0) {
      obj += ",\"width\":" + std::to_string(w) + ",\"height\":" + std::to_string(h);
    }
    obj += "}";
    if (dst->size() > 1) *dst += ",";
    *dst += obj;
  }
  a += "]";
  v += "]";
  s += "]";
  std::lock_guard<std::mutex> lock(core->info_mu);
  core->tracks_audio = a;
  core->tracks_video = v;
  core->tracks_sub = s;
}

void RefreshInfoCache(MpvCore* core, mpv_handle* m) {
  EncodableMap info;
  const std::string hw = GetStr(m, "hwdec");
  const std::string cur = GetStr(m, "hwdec-current");
  const std::string vo = GetStr(m, "current-vo");
  if (!hw.empty()) info[EncodableValue("hwdec")] = EncodableValue(hw);
  if (!cur.empty()) info[EncodableValue("hwdec-current")] = EncodableValue(cur);
  if (!vo.empty()) info[EncodableValue("current-vo")] = EncodableValue(vo);
  int64_t w = 0, h = 0;
  mpv_get_property(m, "dwidth", MPV_FORMAT_INT64, &w);
  mpv_get_property(m, "dheight", MPV_FORMAT_INT64, &h);
  info[EncodableValue("width")] = EncodableValue(static_cast<int32_t>(w));
  info[EncodableValue("height")] = EncodableValue(static_cast<int32_t>(h));
  std::lock_guard<std::mutex> lock(core->info_mu);
  core->info = std::move(info);
}

EncodableMap PositionEvent(mpv_handle* m) {
  double pos = 0, dur = 0, buf = 0, speed = 0;
  int pause = 1, cache = 0, eof = 0, idle = 0, core_idle = 0, seeking = 0;
  mpv_get_property(m, "time-pos", MPV_FORMAT_DOUBLE, &pos);
  mpv_get_property(m, "duration", MPV_FORMAT_DOUBLE, &dur);
  mpv_get_property(m, "demuxer-cache-duration", MPV_FORMAT_DOUBLE, &buf);
  mpv_get_property(m, "cache-speed", MPV_FORMAT_DOUBLE, &speed);
  mpv_get_property(m, "pause", MPV_FORMAT_FLAG, &pause);
  mpv_get_property(m, "paused-for-cache", MPV_FORMAT_FLAG, &cache);
  mpv_get_property(m, "eof-reached", MPV_FORMAT_FLAG, &eof);
  mpv_get_property(m, "idle-active", MPV_FORMAT_FLAG, &idle);
  mpv_get_property(m, "core-idle", MPV_FORMAT_FLAG, &core_idle);
  mpv_get_property(m, "seeking", MPV_FORMAT_FLAG, &seeking);
  const bool playing = pause == 0 && idle == 0 && core_idle == 0;
  const bool buffering = seeking != 0 || cache != 0 || (!playing && eof == 0 && pos <= 0.05);
  const double p = std::isfinite(pos) ? pos : 0;
  const double d = std::isfinite(dur) ? dur : 0;
  const double b = std::isfinite(buf) ? buf : 0;
  return {
      {EncodableValue("event"), EncodableValue("position")},
      {EncodableValue("positionMs"), EncodableValue(static_cast<int64_t>(p * 1000))},
      {EncodableValue("durationMs"), EncodableValue(static_cast<int64_t>((std::max)(0.0, d * 1000)))},
      {EncodableValue("bufferedMs"),
       EncodableValue(static_cast<int64_t>((std::max)(0.0, (p + b) * 1000)))},
      {EncodableValue("playing"), EncodableValue(playing)},
      {EncodableValue("buffering"), EncodableValue(buffering)},
      {EncodableValue("speedBps"),
       EncodableValue(static_cast<int64_t>((std::max)(0.0, std::isfinite(speed) ? speed : 0)))},
  };
}

void EventLoop(std::shared_ptr<MpvCore> core, std::shared_ptr<Bridge> bridge) {
  using clock = std::chrono::steady_clock;
  mpv_handle* m = core->mpv.load();
  auto next_pos = clock::now();
  auto post_event = [&](EncodableMap map) {
    bridge->Post(Posted{Posted::kEvent, core->id, std::move(map)});
  };
  while (!core->stop_events.load() && m) {
    mpv_event* ev = mpv_wait_event(m, 0.05);
    if (!ev) continue;
    if (ev->event_id == MPV_EVENT_SHUTDOWN) break;
    if (ev->event_id == MPV_EVENT_NONE) {
      if (clock::now() >= next_pos) {
        post_event(PositionEvent(m));
        next_pos = clock::now() + std::chrono::milliseconds(300);
      }
      continue;
    }
    if (ev->event_id == MPV_EVENT_FILE_LOADED || ev->event_id == MPV_EVENT_PLAYBACK_RESTART) {
      RefreshInfoCache(core.get(), m);
      RefreshTrackCache(core.get(), m);
      int64_t w = 0, h = 0;
      mpv_get_property(m, "dwidth", MPV_FORMAT_INT64, &w);
      mpv_get_property(m, "dheight", MPV_FORMAT_INT64, &h);
      post_event({{EncodableValue("event"), EncodableValue("ready")},
                  {EncodableValue("width"), EncodableValue(static_cast<int32_t>(w))},
                  {EncodableValue("height"), EncodableValue(static_cast<int32_t>(h))}});
      bridge->Post(Posted{Posted::kShowVideo, core->id, {}});
      post_event(PositionEvent(m));
    } else if (ev->event_id == MPV_EVENT_VIDEO_RECONFIG) {
      RefreshInfoCache(core.get(), m);
      int64_t w = 0, h = 0;
      mpv_get_property(m, "dwidth", MPV_FORMAT_INT64, &w);
      mpv_get_property(m, "dheight", MPV_FORMAT_INT64, &h);
      if (w > 0 && h > 0) {
        post_event({{EncodableValue("event"), EncodableValue("size")},
                    {EncodableValue("width"), EncodableValue(static_cast<int32_t>(w))},
                    {EncodableValue("height"), EncodableValue(static_cast<int32_t>(h))}});
      }
    } else if (ev->event_id == MPV_EVENT_END_FILE) {
      auto* e = static_cast<mpv_event_end_file*>(ev->data);
      if (e && e->reason == MPV_END_FILE_REASON_EOF) {
        post_event({{EncodableValue("event"), EncodableValue("completed")}});
      } else if (e && e->reason == MPV_END_FILE_REASON_ERROR) {
        post_event({{EncodableValue("event"), EncodableValue("error")},
                    {EncodableValue("message"),
                     EncodableValue(std::string("MPV ") + mpv_error_string(e->error))}});
      }
    }
  }
}

// 后台线程：建 mpv、套选项、loadfile。持 core->mu，但 UI 线程从不拿这个锁。
void InitAndOpen(std::shared_ptr<MpvCore> core, std::shared_ptr<Bridge> bridge, uint64_t gen,
                 SessionOpts opts, OpenParams open) {
  std::lock_guard<std::mutex> lock(core->mu);
  if (core->disposed.load() || gen != core->open_gen.load()) return;
  mpv_handle* m = core->mpv.load();
  if (!m) {
    bridge->WaitTeardownIdle();
    if (core->disposed.load() || gen != core->open_gen.load()) return;
    m = mpv_create();
    if (!m) {
      bridge->Post(Posted{Posted::kEvent, core->id,
                          {{EncodableValue("event"), EncodableValue("error")},
                           {EncodableValue("message"), EncodableValue("mpv create failed")}}});
      return;
    }
    int64_t wid = reinterpret_cast<int64_t>(core->hwnd);
    mpv_set_option(m, "wid", MPV_FORMAT_INT64, &wid);
    // Win7 上 d3d11 / gpu-next 可能不可用：按顺序回退到 gpu、direct3d，避免探测卡死。
    mpv_set_option_string(m, "vo", "gpu-next,gpu,direct3d");
    mpv_set_option_string(m, "gpu-api", "auto");
    mpv_set_option_string(m, "gpu-context", "auto");
    mpv_set_option_string(m, "hwdec", ResolveHwdec(opts).c_str());
    mpv_set_option_string(m, "hwdec-software-fallback", "yes");
    mpv_set_option_string(m, "keep-open", "yes");
    mpv_set_option_string(m, "idle", "yes");
    mpv_set_option_string(m, "osc", "no");
    mpv_set_option_string(m, "input-default-bindings", "no");
    mpv_set_option_string(m, "input-vo-keyboard", "no");
    mpv_set_option_string(m, "terminal", "no");
    if (mpv_initialize(m) < 0) {
      mpv_terminate_destroy(m);
      bridge->Post(Posted{Posted::kEvent, core->id,
                          {{EncodableValue("event"), EncodableValue("error")},
                           {EncodableValue("message"), EncodableValue("mpv init failed")}}});
      return;
    }
    core->mpv.store(m);
    core->event_thread = std::thread(EventLoop, core, bridge);
  }
  if (core->disposed.load() || gen != core->open_gen.load()) return;
  ApplySession(m, opts);
  for (const auto& kv : open.props) SetProp(m, kv.first.c_str(), kv.second);
  if (open.url.empty()) return;
  SetProp(m, "http-header-fields", open.headers);
  bridge->Post(Posted{Posted::kHideVideo, core->id, {}});
  // replace 即可换片；勿 stop（打断无缝换集）。
  if (open.start_ms > 0) {
    char start_opt[64];
    snprintf(start_opt, sizeof(start_opt), "start=%.3f", open.start_ms / 1000.0);
    CommandSync(m, {"loadfile", open.url, "replace", "-1", start_opt});
  } else {
    CommandSync(m, {"loadfile", open.url, "replace"});
  }
  CommandSync(m, {"set", "pause", "no"});
}

// 唯一的销毁线程：串行 terminate；结束后把 HWND 交回 UI 线程销毁。
void TeardownWorker(std::shared_ptr<Bridge> bridge) {
  for (;;) {
    std::shared_ptr<MpvCore> core;
    {
      std::unique_lock<std::mutex> lock(bridge->td_mu);
      bridge->td_cv.wait(lock, [&] { return bridge->td_quit || !bridge->td_queue.empty(); });
      if (bridge->td_queue.empty()) return;
      core = std::move(bridge->td_queue.front());
      bridge->td_queue.pop_front();
    }
    {
      std::lock_guard<std::mutex> lock(core->mu);
      core->stop_events.store(true);
      mpv_handle* m = core->mpv.exchange(nullptr);
      if (m) mpv_wakeup(m);
      if (core->event_thread.joinable()) core->event_thread.join();
      if (m) mpv_terminate_destroy(m);
    }
    HWND msg = bridge->msg_hwnd.load();
    if (core->hwnd && msg) {
      PostMessageW(msg, kMsgDestroyHwnd, reinterpret_cast<WPARAM>(core->hwnd), 0);
    }
    {
      std::lock_guard<std::mutex> lock(bridge->td_mu);
      bridge->td_busy--;
    }
    bridge->td_cv.notify_all();
  }
}

#ifndef NDEBUG
// 调试构建：UI 线程看门狗。超过 200ms 无响应就记录当时在处理的方法。
struct Watchdog {
  std::atomic<bool> quit{false};
  std::atomic<const char*> current{"idle"};
  std::thread th;

  void Start(HWND target) {
    th = std::thread([this, target] {
      wchar_t path[MAX_PATH];
      GetTempPathW(MAX_PATH, path);
      wcscat_s(path, L"kotv_mpv_watchdog.log");
      while (!quit.load()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        if (!IsWindow(target)) continue;
        const auto t0 = std::chrono::steady_clock::now();
        DWORD_PTR res = 0;
        if (!SendMessageTimeoutW(target, WM_NULL, 0, 0, SMTO_ABORTIFHUNG, 200, &res)) {
          while (!quit.load() && !SendMessageTimeoutW(target, WM_NULL, 0, 0, SMTO_ABORTIFHUNG,
                                                      200, &res)) {
          }
          const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                              std::chrono::steady_clock::now() - t0)
                              .count();
          FILE* f = _wfopen(path, L"a");
          if (f) {
            fprintf(f, "UI blocked %lld ms during %s\n", static_cast<long long>(ms),
                    current.load());
            fclose(f);
          }
        }
      }
    });
  }
  void Stop() {
    quit.store(true);
    if (th.joinable()) th.join();
  }
};
#endif

class KotvMpvPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
    auto plugin = std::make_unique<KotvMpvPlugin>(registrar);
    registrar->AddPlugin(std::move(plugin));
  }

  explicit KotvMpvPlugin(flutter::PluginRegistrarWindows* registrar)
      : registrar_(registrar), bridge_(std::make_shared<Bridge>()) {
    channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        registrar->messenger(), "kotv_mpv", &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler(
        [this](const auto& call, auto result) { Handle(call, std::move(result)); });

    events_ = std::make_unique<flutter::EventChannel<EncodableValue>>(
        registrar->messenger(), "kotv_mpv/events", &flutter::StandardMethodCodec::GetInstance());
    events_->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
        [this](const EncodableValue*, std::unique_ptr<flutter::EventSink<EncodableValue>>&& sink) {
          sink_ = std::move(sink);
          return nullptr;
        },
        [this](const EncodableValue*) {
          sink_.reset();
          return nullptr;
        }));

    CreateBridgeWindow();
    {
      std::lock_guard<std::mutex> lock(bridge_->td_mu);
      bridge_->td_started = true;
    }
    std::thread(TeardownWorker, bridge_).detach();
#ifndef NDEBUG
    if (HWND root = RootHwnd()) watchdog_.Start(root);
#endif
  }

  ~KotvMpvPlugin() override {
#ifndef NDEBUG
    watchdog_.Stop();
#endif
    DisposeCurrent();
    {
      std::lock_guard<std::mutex> lock(bridge_->td_mu);
      bridge_->td_quit = true;
    }
    bridge_->td_cv.notify_all();
    HWND msg = bridge_->msg_hwnd.exchange(nullptr);
    if (msg) DestroyWindow(msg);
  }

 private:
  HWND FlutterHwnd() {
    return registrar_->GetView() ? registrar_->GetView()->GetNativeWindow() : nullptr;
  }

  HWND RootHwnd() {
    HWND v = FlutterHwnd();
    return v ? GetAncestor(v, GA_ROOT) : nullptr;
  }

  // Win7 原生播控面板是 Flutter 视图的兄弟子窗：视频压到最底，手势层再压到视频之下。
  void NotifySurface() {
    HWND parent = FlutterHwnd();
    if (!parent || !core_ || !core_->hwnd) return;
    constexpr UINT kFlags = SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE;
    SetWindowPos(core_->hwnd, HWND_BOTTOM, 0, 0, 0, 0, kFlags);
    HWND child = nullptr;
    while ((child = FindWindowExW(parent, child, L"KotvWinChromeGesture", nullptr)) != nullptr) {
      SetWindowPos(child, HWND_BOTTOM, 0, 0, 0, 0, kFlags);
    }
  }

  void HideVideo(HWND h) {
    if (h && IsWindowVisible(h)) {
      ShowWindow(h, SW_HIDE);
      NotifySurface();
    }
  }

  void CreateBridgeWindow() {
    static bool registered = false;
    if (!registered) {
      WNDCLASSW wc{};
      wc.lpfnWndProc = BridgeWndProc;
      wc.hInstance = GetModuleHandleW(nullptr);
      wc.lpszClassName = kBridgeClass;
      RegisterClassW(&wc);
      registered = true;
    }
    HWND h = CreateWindowExW(0, kBridgeClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr,
                             GetModuleHandleW(nullptr), nullptr);
    if (h) SetWindowLongPtrW(h, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
    bridge_->msg_hwnd.store(h);
  }

  static LRESULT CALLBACK BridgeWndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    auto* self = reinterpret_cast<KotvMpvPlugin*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (msg == kMsgDestroyHwnd) {
      HWND v = reinterpret_cast<HWND>(wp);
      if (v && IsWindow(v)) DestroyWindow(v);
      return 0;
    }
    if (msg == kMsgDrain && self) {
      self->Drain();
      return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
  }

  // UI 线程：处理后台投递。旧实例（core_id 不匹配）的事件直接丢弃。
  void Drain() {
    std::deque<Posted> batch;
    {
      std::lock_guard<std::mutex> lock(bridge_->q_mu);
      batch.swap(bridge_->queue);
    }
    for (auto& p : batch) {
      if (!core_ || p.core_id != core_->id) continue;
      switch (p.kind) {
        case Posted::kEvent:
          if (sink_) sink_->Success(EncodableValue(std::move(p.map)));
          break;
        case Posted::kShowVideo:
          ShowVideo();
          break;
        case Posted::kHideVideo:
          HideVideo(core_->hwnd);
          break;
      }
    }
  }

  void EmitNow(EncodableMap map) {
    if (sink_) sink_->Success(EncodableValue(std::move(map)));
  }

  void ShowVideo() {
    if (!core_ || !core_->hwnd || !visible_ || !have_frame_) return;
    if (IsWindowVisible(core_->hwnd)) return;
    ShowWindow(core_->hwnd, SW_SHOWNOACTIVATE);
    NotifySurface();
  }

  double FrameDpr() {
    double dpr = frame_dpr_;
    if (dpr <= 0) {
      if (HWND parent = FlutterHwnd()) {
        if (HDC dc = GetDC(parent)) {
          dpr = GetDeviceCaps(dc, LOGPIXELSX) / 96.0;
          ReleaseDC(parent, dc);
        }
      }
    }
    return dpr <= 0 ? 1.0 : dpr;
  }

  // 可见区（Win7 详情页滚到顶栏下时）用窗口区域裁掉，画面不缩放。
  void ApplyClipRegion(HWND hwnd, int cx, int cy, int cw, int ch) {
    RECT keep{0, 0, cw, ch};
    if (has_clip_) {
      const double dpr = FrameDpr();
      RECT c{static_cast<LONG>(std::lround(clip_x_ * dpr)) - cx, static_cast<LONG>(std::lround(clip_y_ * dpr)) - cy,
             static_cast<LONG>(std::lround((clip_x_ + clip_w_) * dpr)) - cx,
             static_cast<LONG>(std::lround((clip_y_ + clip_h_) * dpr)) - cy};
      if (!IntersectRect(&keep, &keep, &c)) keep = RECT{0, 0, 0, 0};
    }
    const bool full = keep.left == 0 && keep.top == 0 && keep.right == cw && keep.bottom == ch;
    if (full && !region_set_) return;
    if (region_set_ && EqualRect(&keep, &region_)) return;
    if (full) {
      SetWindowRgn(hwnd, nullptr, TRUE);
      region_set_ = false;
      return;
    }
    SetWindowRgn(hwnd, CreateRectRgn(keep.left, keep.top, keep.right, keep.bottom), TRUE);
    region_ = keep;
    region_set_ = true;
  }

  bool ResolveFramePhysical(int* cx, int* cy, int* cw, int* ch) {
    if (!have_frame_ || frame_w_ <= 1 || frame_h_ <= 1) {
      // 槽几何未到：先按占位尺寸建隐藏 HWND 供 mpv 绑定 wid，updateFrame 再挪到位并显示。
      *cx = *cy = 0;
      *cw = 16;
      *ch = 9;
      return true;
    }
    const double dpr = FrameDpr();
    *cx = static_cast<int>(std::lround(frame_x_ * dpr));
    *cy = static_cast<int>(std::lround(frame_y_ * dpr));
    *cw = (std::max)(1, static_cast<int>(std::lround(frame_w_ * dpr)));
    *ch = (std::max)(1, static_cast<int>(std::lround(frame_h_ * dpr)));
    return *cw > 1 && *ch > 1;
  }

  MpvCore* EnsureCore() {
    if (!core_) {
      core_ = std::make_shared<MpvCore>();
      core_->id = ++next_core_id_;
    }
    return core_.get();
  }

  // 只按槽建/挪 HWND（快）。mpv_initialize 只在后台线程。
  bool EnsureVideoHwnd() {
    HWND parent = FlutterHwnd();
    if (!parent) return false;
    int cx = 0, cy = 0, cw = 0, ch = 0;
    if (!ResolveFramePhysical(&cx, &cy, &cw, &ch)) return false;
    MpvCore* core = EnsureCore();
    if (!core->hwnd) {
      core->hwnd = CreateWindowExW(WS_EX_NOPARENTNOTIFY, L"STATIC", L"",
                                   WS_CHILD | WS_CLIPSIBLINGS | WS_DISABLED, cx, cy, cw, ch,
                                   parent, nullptr, GetModuleHandleW(nullptr), nullptr);
      if (!core->hwnd) return false;
      region_set_ = false;
      ShowWindow(core->hwnd, SW_HIDE);
    } else {
      MoveWindow(core->hwnd, cx, cy, cw, ch, TRUE);
      if (IsWindowVisible(core->hwnd)) NotifySurface();
    }
    ApplyClipRegion(core->hwnd, cx, cy, cw, ch);
    return true;
  }

  mpv_handle* Mpv() { return core_ ? core_->mpv.load() : nullptr; }

  void IngestSession(const EncodableMap* args) {
    opts_.decode_mode = ArgString(args, "decode", opts_.decode_mode);
    opts_.direct = ArgBool(args, "direct", opts_.direct);
    const auto hw = ArgString(args, "hwdec");
    if (!hw.empty()) opts_.hwdec = hw;
    if (HasArg(args, "conf")) opts_.conf = ArgString(args, "conf");
    if (HasArg(args, "diskCache")) opts_.disk_cache = ArgBool(args, "diskCache");
    if (HasArg(args, "live")) opts_.live = ArgBool(args, "live");
    if (HasArg(args, "dolbyVisionPolicy")) {
      opts_.dovi_policy = static_cast<int>(ArgInt64(args, "dolbyVisionPolicy"));
    }
    if (HasArg(args, "repeatOne")) opts_.repeat_one = ArgBool(args, "repeatOne");
    if (HasArg(args, "audioOffsetMs")) {
      opts_.audio_delay = FmtNum(ArgDouble(args, "audioOffsetMs") / 1000.0);
    }
    IngestEqualizer(args);
  }

  void IngestEqualizer(const EncodableMap* args) {
    auto eq = [&](const char* k, int* dst) {
      if (!HasArg(args, k)) return;
      *dst = std::clamp(static_cast<int>(ArgInt64(args, k)), -100, 100);
      opts_.has_eq = true;
    };
    eq("eqBrightness", &opts_.eq_brightness);
    eq("eqContrast", &opts_.eq_contrast);
    eq("eqSaturation", &opts_.eq_saturation);
    eq("eqGamma", &opts_.eq_gamma);
    eq("eqHue", &opts_.eq_hue);
    if (HasArg(args, "audioAf")) {
      opts_.audio_af = ArgString(args, "audioAf");
      opts_.has_af = true;
    }
    if (HasArg(args, "videoVf")) {
      opts_.video_vf = ArgString(args, "videoVf");
      opts_.has_vf = true;
    }
    if (HasArg(args, "subtitleFontScale")) {
      opts_.sub_scale = FmtNum(std::clamp(ArgDouble(args, "subtitleFontScale", 1.0), 0.5, 2.0));
    }
  }

  static std::string ExtractHttpHeaders(const EncodableMap* args) {
    if (!args) return {};
    auto hit = args->find(EncodableValue("headers"));
    if (hit == args->end()) return {};
    const auto* headers = std::get_if<EncodableMap>(&hit->second);
    if (!headers) return {};
    std::string fields;
    for (const auto& kv : *headers) {
      const auto* k = std::get_if<std::string>(&kv.first);
      const auto* v = std::get_if<std::string>(&kv.second);
      if (!k || !v) continue;
      if (!fields.empty()) fields += ",";
      fields += *k + ": " + *v;
    }
    return fields;
  }

  static std::map<std::string, std::string> ExtractProps(const EncodableMap* args) {
    std::map<std::string, std::string> out;
    if (!args) return out;
    auto pit = args->find(EncodableValue("props"));
    if (pit == args->end()) return out;
    const auto* props = std::get_if<EncodableMap>(&pit->second);
    if (!props) return out;
    for (const auto& kv : *props) {
      const auto* k = std::get_if<std::string>(&kv.first);
      if (!k) continue;
      std::string v;
      if (const auto* s = std::get_if<std::string>(&kv.second)) v = *s;
      else if (const auto* b = std::get_if<bool>(&kv.second)) v = *b ? "yes" : "no";
      else if (const auto* i = std::get_if<int32_t>(&kv.second)) v = std::to_string(*i);
      else if (const auto* i64 = std::get_if<int64_t>(&kv.second)) v = std::to_string(*i64);
      else if (const auto* d = std::get_if<double>(&kv.second)) v = FmtNum(*d);
      if (!v.empty()) out[*k] = std::move(v);
    }
    return out;
  }

  void ScheduleOpen(OpenParams open) {
    MpvCore* core = EnsureCore();
    const uint64_t gen = ++core->open_gen;
    std::thread(InitAndOpen, core_, bridge_, gen, opts_, std::move(open)).detach();
  }

  // UI 线程不等：当前实例移交销毁线程，HWND 先隐藏，销毁完再由 UI 线程 DestroyWindow。
  void DisposeCurrent() {
    if (!core_) return;
    std::shared_ptr<MpvCore> old = std::move(core_);
    old->disposed.store(true);
    old->open_gen++;
    HideVideo(old->hwnd);
    {
      std::lock_guard<std::mutex> lock(bridge_->td_mu);
      bridge_->td_queue.push_back(old);
      bridge_->td_busy++;
    }
    bridge_->td_cv.notify_all();
  }

  void ApplySubtitleStyle(mpv_handle* m, const EncodableMap* args) {
    if (HasArg(args, "scale")) {
      SetProp(m, "sub-scale", FmtNum(std::clamp(ArgDouble(args, "scale", 1.0), 0.5, 2.0)));
    }
    if (HasArg(args, "pos")) {
      SetProp(m, "sub-pos", FmtNum(std::clamp(100.0 - ArgDouble(args, "pos"), 0.0, 150.0)));
    }
    if (HasArg(args, "secondaryPos")) {
      SetProp(m, "secondary-sub-pos",
              FmtNum(std::clamp(ArgDouble(args, "secondaryPos"), 0.0, 150.0)));
    }
    const bool looks = ArgBool(args, "forceStyle") || ArgBool(args, "useSystemStyle");
    if (!looks) return;
    auto with_opacity = [&](const char* color_key, const char* opacity_key) {
      const std::string c = ArgString(args, color_key);
      if (c.empty()) return std::string();
      return HasArg(args, opacity_key) ? ApplySubtitleOpacity(c, ArgDouble(args, opacity_key))
                                       : c;
    };
    const std::string color = with_opacity("color", "textOpacity");
    if (!color.empty()) SetProp(m, "sub-color", color);
    const std::string border = with_opacity("borderColor", "edgeOpacity");
    if (!border.empty()) SetProp(m, "sub-border-color", border);
    const bool has_border = HasArg(args, "borderSize");
    if (has_border) {
      SetProp(m, "sub-border-size", FmtNum(std::clamp(ArgDouble(args, "borderSize"), 0.0, 8.0)));
    }
    const std::string bg = with_opacity("bgColor", "bgOpacity");
    if (!bg.empty()) SetProp(m, "sub-back-color", bg);
    const double strength =
        std::clamp(std::clamp(ArgDouble(args, "shadowStrength", 50.0), 0.0, 100.0) / 50.0, 0.0,
                   2.5);
    std::string edge = ArgString(args, "edgeType");
    for (auto& ch : edge) ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    if (edge == "none") {
      SetProp(m, "sub-border-size", "0");
      SetProp(m, "sub-shadow-offset", "0");
    } else if (edge == "shadow") {
      SetProp(m, "sub-shadow-offset", FmtNum(2.0 * strength));
    } else if (edge == "raised" || edge == "depressed") {
      SetProp(m, "sub-shadow-offset", FmtNum(1.5 * strength));
    } else if (edge == "outline") {
      if (!has_border) SetProp(m, "sub-border-size", "2");
      SetProp(m, "sub-shadow-offset", "0");
    }
    const std::string font = ArgString(args, "font");
    if (!font.empty()) SetProp(m, "sub-font", font);
    const std::string font_path = ArgString(args, "fontPath");
    if (!font_path.empty()) {
      const auto slash = font_path.find_last_of("\\/");
      if (slash != std::string::npos) SetProp(m, "sub-fonts-dir", font_path.substr(0, slash));
    }
  }

  void Handle(const flutter::MethodCall<EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    const auto& method = call.method_name();
#ifndef NDEBUG
    watchdog_.current.store(method.c_str());
    struct Reset {
      Watchdog& w;
      ~Reset() { w.current.store("idle"); }
    } reset{watchdog_};
#endif

    if (method == "isVulkanAvailable") {
      result->Success(EncodableValue(false));
      return;
    }
    if (method == "create") {
      IngestSession(args);
      EnsureCore();
      if (have_frame_) EnsureVideoHwnd();
      result->Success(EncodableValue(EncodableMap{
          {EncodableValue("ok"), EncodableValue(true)},
          {EncodableValue("ready"), EncodableValue(true)},
          {EncodableValue("deferred"), EncodableValue(Mpv() == nullptr)},
      }));
      return;
    }
    if (method == "open") {
      IngestSession(args);
      OpenParams open;
      open.url = ArgString(args, "url");
      open.start_ms = ArgInt64(args, "startAtMs");
      open.headers = ExtractHttpHeaders(args);
      open.props = ExtractProps(args);
      if (!EnsureVideoHwnd()) {
        result->Error("NO_HWND", "video window unavailable");
        return;
      }
      ScheduleOpen(std::move(open));
      result->Success();
      return;
    }
    if (method == "play") {
      CommandAsync(Mpv(), {"set", "pause", "no"});
      result->Success();
      return;
    }
    if (method == "pause") {
      CommandAsync(Mpv(), {"set", "pause", "yes"});
      result->Success();
      return;
    }
    if (method == "stop") {
      // 与随后的 loadfile 在同一实例内按序执行，UI 不等。
      if (core_) core_->open_gen++;
      CommandAsync(Mpv(), {"stop"});
      if (core_) HideVideo(core_->hwnd);
      result->Success();
      return;
    }
    if (method == "dispose") {
      DisposeCurrent();
      have_frame_ = false;
      visible_ = false;
      frame_x_ = frame_y_ = frame_w_ = frame_h_ = 0;
      frame_dpr_ = 0;
      has_clip_ = false;
      region_set_ = false;
      result->Success();
      return;
    }
    if (method == "seek") {
      char sec[64];
      snprintf(sec, sizeof(sec), "%.3f", ArgInt64(args, "positionMs") / 1000.0);
      CommandAsync(Mpv(), {"seek", sec, "absolute"});
      result->Success();
      return;
    }
    if (method == "setVolume") {
      opts_.volume = FmtNum(std::clamp(ArgDouble(args, "volume", 100), 0.0, 100.0));
      SetProp(Mpv(), "volume", opts_.volume);
      result->Success();
      return;
    }
    if (method == "setRate") {
      opts_.speed = FmtNum(ArgDouble(args, "rate", 1));
      SetProp(Mpv(), "speed", opts_.speed);
      result->Success();
      return;
    }
    if (method == "setDecode" || method == "setOpts") {
      IngestSession(args);
      if (mpv_handle* m = Mpv()) {
        ApplySession(m, opts_);
        for (const auto& kv : ExtractProps(args)) SetProp(m, kv.first.c_str(), kv.second);
      }
      result->Success();
      return;
    }
    if (method == "setAspect") {
      opts_.aspect = ArgString(args, "mode", "default");
      ApplyAspect(Mpv(), opts_.aspect);
      result->Success();
      return;
    }
    if (method == "setRepeatOne") {
      opts_.repeat_one = ArgBool(args, "on");
      SetProp(Mpv(), "loop-file", opts_.repeat_one ? "inf" : "no");
      result->Success();
      return;
    }
    if (method == "setAudioOffsetMs") {
      const double ms = HasArg(args, "ms") ? ArgDouble(args, "ms") : ArgDouble(args, "audioOffsetMs");
      opts_.audio_delay = FmtNum(ms / 1000.0);
      SetProp(Mpv(), "audio-delay", opts_.audio_delay);
      result->Success();
      return;
    }
    if (method == "setSubtitleOffsetMs") {
      opts_.sub_delay = FmtNum(ArgDouble(args, "ms") / 1000.0);
      SetProp(Mpv(), "sub-delay", opts_.sub_delay);
      result->Success();
      return;
    }
    if (method == "setEqualizer") {
      IngestEqualizer(args);
      ApplyEqualizer(Mpv(), opts_);
      result->Success();
      return;
    }
    if (method == "setAudioTrack" || method == "setVideoTrack" || method == "setSubtitleTrack" ||
        method == "setSecondarySubtitleTrack") {
      std::string id = ArgString(args, "id");
      const char* prop = method == "setAudioTrack"   ? "aid"
                         : method == "setVideoTrack" ? "vid"
                         : method == "setSubtitleTrack" ? "sid"
                                                        : "secondary-sid";
      std::string key = id;
      for (auto& ch : key) ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
      if (key.empty() || key == "off" || key == "none") id = key.empty() ? "auto" : "no";
      CommandAsync(Mpv(), {"set", prop, id});
      result->Success();
      return;
    }
    if (method == "addSubtitle") {
      std::string path = ArgString(args, "path");
      if (path.empty()) path = ArgString(args, "url");
      if (!path.empty()) {
        const bool select = ArgBool(args, "select", true);
        const std::string title = ArgString(args, "title");
        if (title.empty()) {
          CommandAsync(Mpv(), {"sub-add", path, select ? "select" : "auto"});
        } else {
          CommandAsync(Mpv(), {"sub-add", path, select ? "select" : "auto", title});
        }
      }
      result->Success();
      return;
    }
    if (method == "setSubtitleStyle") {
      ApplySubtitleStyle(Mpv(), args);
      result->Success();
      return;
    }
    if (method == "setVisible") {
      visible_ = ArgBool(args, "visible");
      if (core_ && core_->hwnd) {
        // 无有效几何前不 Show，避免默认窗停在客户区左上角。
        if (visible_ && have_frame_) {
          ShowVideo();
        } else {
          HideVideo(core_->hwnd);
        }
      }
      result->Success();
      return;
    }
    if (method == "updateFrame" || method == "setVideoRect") {
      if (args) {
        const double x = ArgDouble(args, "x");
        const double y = ArgDouble(args, "y");
        const double w = ArgDouble(args, "w", ArgDouble(args, "width"));
        const double h = ArgDouble(args, "h", ArgDouble(args, "height"));
        const double dpr = ArgDouble(args, "dpr", 0);
        if (w > 1 && h > 1) {
          const bool clip = HasArg(args, "clipW");
          const double kx = clip ? ArgDouble(args, "clipX") : 0, ky = clip ? ArgDouble(args, "clipY") : 0;
          const double kw = clip ? ArgDouble(args, "clipW") : 0, kh = clip ? ArgDouble(args, "clipH") : 0;
          const bool clip_changed = clip != has_clip_ || std::abs(kx - clip_x_) > 0.5 || std::abs(ky - clip_y_) > 0.5 ||
                                    std::abs(kw - clip_w_) > 0.5 || std::abs(kh - clip_h_) > 0.5;
          has_clip_ = clip;
          clip_x_ = kx;
          clip_y_ = ky;
          clip_w_ = kw;
          clip_h_ = kh;
          const bool moved = !have_frame_ || clip_changed || std::abs(x - frame_x_) > 0.5 ||
                             std::abs(y - frame_y_) > 0.5 || std::abs(w - frame_w_) > 0.5 ||
                             std::abs(h - frame_h_) > 0.5;
          frame_x_ = x;
          frame_y_ = y;
          frame_w_ = w;
          frame_h_ = h;
          if (dpr > 0) frame_dpr_ = dpr;
          have_frame_ = true;
          const bool need_hwnd = !core_ || !core_->hwnd;
          // 几何未变勿 MoveWindow；已可见勿再 ShowWindow。
          if (moved || need_hwnd) EnsureVideoHwnd();
          if (visible_ && Mpv() && core_->hwnd && !IsWindowVisible(core_->hwnd)) ShowVideo();
        }
      }
      result->Success();
      return;
    }
    if (method == "videoInfo") {
      EncodableMap info;
      if (core_) {
        std::lock_guard<std::mutex> lock(core_->info_mu);
        info = core_->info;
      }
      result->Success(EncodableValue(info));
      return;
    }
    if (method == "getAudioTracks" || method == "getVideoTracks" ||
        method == "getSubtitleTracks") {
      std::string json = "[]";
      if (core_) {
        std::lock_guard<std::mutex> lock(core_->info_mu);
        json = method == "getAudioTracks"   ? core_->tracks_audio
               : method == "getVideoTracks" ? core_->tracks_video
                                            : core_->tracks_sub;
      }
      result->Success(EncodableValue(json));
      return;
    }
    if (method == "setRenderMode" || method == "setSurfaceLayerEnabled" ||
        method == "setDiscTitle" || method == "setDiscChapter" || method == "openDiscMenu" ||
        method == "retryVideo") {
      result->Success();
      return;
    }
    if (method == "queueNext" || method == "clearNext" || method == "skipToNext") {
      result->Success(EncodableValue(false));
      return;
    }
    if (method == "discTitleCount" || method == "discChapterCount") {
      result->Success(EncodableValue(0));
      return;
    }
    result->NotImplemented();
  }

  flutter::PluginRegistrarWindows* registrar_;
  std::shared_ptr<Bridge> bridge_;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> events_;
  std::unique_ptr<flutter::EventSink<EncodableValue>> sink_;

  std::shared_ptr<MpvCore> core_;
  uint64_t next_core_id_ = 0;
  SessionOpts opts_;
  bool visible_ = false;
  bool have_frame_ = false;
  double frame_x_ = 0;
  double frame_y_ = 0;
  double frame_w_ = 0;
  double frame_h_ = 0;
  double frame_dpr_ = 0;
  bool has_clip_ = false;
  double clip_x_ = 0;
  double clip_y_ = 0;
  double clip_w_ = 0;
  double clip_h_ = 0;
  bool region_set_ = false;
  RECT region_{};
#ifndef NDEBUG
  Watchdog watchdog_;
#endif
};

}  // namespace

void KotvMpvPluginRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  KotvMpvPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
