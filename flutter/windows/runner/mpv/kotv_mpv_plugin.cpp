#include "kotv_mpv_plugin.h"

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <mpv/client.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

std::string ArgString(const EncodableMap* m, const char* key, const std::string& def = "") {
  if (!m) return def;
  auto it = m->find(EncodableValue(key));
  if (it == m->end()) return def;
  if (const auto* s = std::get_if<std::string>(&it->second)) return *s;
  return def;
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

class KotvMpvPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
    auto plugin = std::make_unique<KotvMpvPlugin>(registrar);
    registrar->AddPlugin(std::move(plugin));
  }

  explicit KotvMpvPlugin(flutter::PluginRegistrarWindows* registrar)
      : registrar_(registrar) {
    channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        registrar->messenger(), "kotv_mpv",
        &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler(
        [this](const auto& call, auto result) { Handle(call, std::move(result)); });

    events_ = std::make_unique<flutter::EventChannel<EncodableValue>>(
        registrar->messenger(), "kotv_mpv/events",
        &flutter::StandardMethodCodec::GetInstance());
    events_->SetStreamHandler(
        std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
            [this](const EncodableValue*,
                   std::unique_ptr<flutter::EventSink<EncodableValue>>&& sink) {
              std::lock_guard<std::mutex> lock(sink_mu_);
              sink_ = std::move(sink);
              return nullptr;
            },
            [this](const EncodableValue*) {
              std::lock_guard<std::mutex> lock(sink_mu_);
              sink_.reset();
              return nullptr;
            }));
  }

  ~KotvMpvPlugin() override { Destroy(); }

 private:
  void Emit(EncodableMap map) {
    std::lock_guard<std::mutex> lock(sink_mu_);
    if (sink_) sink_->Success(EncodableValue(map));
  }

  HWND FlutterHwnd() {
    return registrar_->GetView() ? registrar_->GetView()->GetNativeWindow() : nullptr;
  }

  bool EnsureMpv() {
    if (mpv_) return true;
    HWND parent = FlutterHwnd();
    if (!parent) return false;

    hwnd_ = CreateWindowExW(WS_EX_NOPARENTNOTIFY, L"STATIC", L"",
                            WS_CHILD | WS_CLIPSIBLINGS | WS_DISABLED, 0, 0, 100, 100,
                            parent, nullptr, GetModuleHandle(nullptr), nullptr);
    if (!hwnd_) return false;

    mpv_ = mpv_create();
    if (!mpv_) {
      DestroyWindow(hwnd_);
      hwnd_ = nullptr;
      return false;
    }

    int64_t wid = reinterpret_cast<int64_t>(hwnd_);
    mpv_set_option(mpv_, "wid", MPV_FORMAT_INT64, &wid);
    mpv_set_option_string(mpv_, "vo", "gpu-next");
    mpv_set_option_string(mpv_, "gpu-api", "auto");
    mpv_set_option_string(mpv_, "hwdec", "auto");
    mpv_set_option_string(mpv_, "hwdec-software-fallback", "yes");
    mpv_set_option_string(mpv_, "keep-open", "yes");
    mpv_set_option_string(mpv_, "idle", "yes");
    mpv_set_option_string(mpv_, "osc", "no");
    mpv_set_option_string(mpv_, "input-default-bindings", "no");
    mpv_set_option_string(mpv_, "input-vo-keyboard", "no");
    mpv_set_option_string(mpv_, "terminal", "no");
    if (mpv_initialize(mpv_) < 0) {
      Destroy();
      return false;
    }
    ShowWindow(hwnd_, SW_HIDE);
    ApplyDecode();
    stop_events_ = false;
    event_thread_ = std::thread([this] { EventLoop(); });
    return true;
  }

  void Destroy() {
    stop_events_ = true;
    if (mpv_) mpv_wakeup(mpv_);
    if (event_thread_.joinable()) event_thread_.join();
    if (mpv_) {
      mpv_terminate_destroy(mpv_);
      mpv_ = nullptr;
    }
    if (hwnd_) {
      DestroyWindow(hwnd_);
      hwnd_ = nullptr;
    }
  }

  void ApplyDecode() {
    if (!mpv_) return;
    // 优先 Dart 下发的 hwdec（KotvMpvOpts.hwdecValue）；无则按 decode/direct 兜底。
    if (!hwdec_.empty()) {
      mpv_set_property_string(mpv_, "hwdec", hwdec_.c_str());
      return;
    }
    if (decode_mode_ == "soft" || decode_mode_ == "no" || decode_mode_ == "sw") {
      mpv_set_property_string(mpv_, "hwdec", "no");
    } else if (direct_) {
      mpv_set_property_string(mpv_, "hwdec", "dxva2");
    } else {
      mpv_set_property_string(mpv_, "hwdec", "auto");
    }
  }

  void IngestDecodeArgs(const EncodableMap* args) {
    decode_mode_ = ArgString(args, "decode", decode_mode_);
    direct_ = ArgBool(args, "direct", direct_);
    const auto hw = ArgString(args, "hwdec");
    if (!hw.empty()) hwdec_ = hw;
  }

  void Command(const std::vector<std::string>& args) {
    if (!mpv_ || args.empty()) return;
    std::vector<const char*> c;
    c.reserve(args.size() + 1);
    for (const auto& a : args) c.push_back(a.c_str());
    c.push_back(nullptr);
    mpv_command(mpv_, c.data());
  }

  void EmitPosition() {
    if (!mpv_) return;
    double pos = 0, dur = 0, buf = 0, speed = 0;
    int pause = 1, cache = 0, eof = 0, idle = 0, core_idle = 0, seeking = 0;
    mpv_get_property(mpv_, "time-pos", MPV_FORMAT_DOUBLE, &pos);
    mpv_get_property(mpv_, "duration", MPV_FORMAT_DOUBLE, &dur);
    mpv_get_property(mpv_, "demuxer-cache-duration", MPV_FORMAT_DOUBLE, &buf);
    mpv_get_property(mpv_, "cache-speed", MPV_FORMAT_DOUBLE, &speed);
    mpv_get_property(mpv_, "pause", MPV_FORMAT_FLAG, &pause);
    mpv_get_property(mpv_, "paused-for-cache", MPV_FORMAT_FLAG, &cache);
    mpv_get_property(mpv_, "eof-reached", MPV_FORMAT_FLAG, &eof);
    mpv_get_property(mpv_, "idle-active", MPV_FORMAT_FLAG, &idle);
    mpv_get_property(mpv_, "core-idle", MPV_FORMAT_FLAG, &core_idle);
    mpv_get_property(mpv_, "seeking", MPV_FORMAT_FLAG, &seeking);
    const bool playing = pause == 0 && idle == 0 && core_idle == 0;
    const bool buffering =
        seeking != 0 || cache != 0 || (!playing && eof == 0 && pos <= 0.05);
    Emit({
        {EncodableValue("event"), EncodableValue("position")},
        {EncodableValue("positionMs"),
         EncodableValue(static_cast<int64_t>((std::isfinite(pos) ? pos : 0) * 1000))},
        {EncodableValue("durationMs"),
         EncodableValue(static_cast<int64_t>(
             (std::max)(0.0, (std::isfinite(dur) ? dur : 0) * 1000)))},
        {EncodableValue("bufferedMs"),
         EncodableValue(static_cast<int64_t>(
             (std::max)(0.0, ((std::isfinite(pos) ? pos : 0) + (std::isfinite(buf) ? buf : 0)) *
                                 1000)))},
        {EncodableValue("playing"), EncodableValue(playing)},
        {EncodableValue("buffering"), EncodableValue(buffering)},
        {EncodableValue("speedBps"),
         EncodableValue(static_cast<int64_t>((std::max)(0.0, std::isfinite(speed) ? speed : 0)))},
    });
  }

  EncodableMap VideoInfo() {
    EncodableMap m;
    if (!mpv_) return m;
    char* hw = mpv_get_property_string(mpv_, "hwdec");
    char* cur = mpv_get_property_string(mpv_, "hwdec-current");
    char* vo = mpv_get_property_string(mpv_, "current-vo");
    if (hw) {
      m[EncodableValue("hwdec")] = EncodableValue(std::string(hw));
      mpv_free(hw);
    }
    if (cur) {
      m[EncodableValue("hwdec-current")] = EncodableValue(std::string(cur));
      mpv_free(cur);
    }
    if (vo) {
      m[EncodableValue("current-vo")] = EncodableValue(std::string(vo));
      mpv_free(vo);
    }
    int64_t w = 0, h = 0;
    mpv_get_property(mpv_, "dwidth", MPV_FORMAT_INT64, &w);
    mpv_get_property(mpv_, "dheight", MPV_FORMAT_INT64, &h);
    m[EncodableValue("width")] = EncodableValue(static_cast<int32_t>(w));
    m[EncodableValue("height")] = EncodableValue(static_cast<int32_t>(h));
    return m;
  }

  void EventLoop() {
    using clock = std::chrono::steady_clock;
    auto next_pos = clock::now();
    while (!stop_events_) {
      if (!mpv_) break;
      mpv_event* ev = mpv_wait_event(mpv_, 0.05);
      if (!ev) continue;
      if (ev->event_id == MPV_EVENT_NONE) {
        if (clock::now() >= next_pos) {
          EmitPosition();
          next_pos = clock::now() + std::chrono::milliseconds(300);
        }
        continue;
      }
      if (ev->event_id == MPV_EVENT_SHUTDOWN) break;
      if (ev->event_id == MPV_EVENT_FILE_LOADED ||
          ev->event_id == MPV_EVENT_PLAYBACK_RESTART) {
        int64_t w = 0, h = 0;
        mpv_get_property(mpv_, "dwidth", MPV_FORMAT_INT64, &w);
        mpv_get_property(mpv_, "dheight", MPV_FORMAT_INT64, &h);
        Emit({{EncodableValue("event"), EncodableValue("ready")},
              {EncodableValue("width"), EncodableValue(static_cast<int32_t>(w))},
              {EncodableValue("height"), EncodableValue(static_cast<int32_t>(h))}});
        if (visible_) ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
        EmitPosition();
      } else if (ev->event_id == MPV_EVENT_END_FILE) {
        auto* e = static_cast<mpv_event_end_file*>(ev->data);
        if (e && e->reason == MPV_END_FILE_REASON_EOF) {
          Emit({{EncodableValue("event"), EncodableValue("completed")}});
        } else if (e && e->reason == MPV_END_FILE_REASON_ERROR) {
          Emit({{EncodableValue("event"), EncodableValue("error")},
                {EncodableValue("message"),
                 EncodableValue(std::string("MPV ") + mpv_error_string(e->error))}});
        }
      }
    }
  }

  void Handle(const flutter::MethodCall<EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    const auto& method = call.method_name();

    if (method == "isVulkanAvailable") {
      result->Success(EncodableValue(false));
      return;
    }
    if (method == "create") {
      IngestDecodeArgs(args);
      if (!EnsureMpv()) {
        result->Error("CREATE_FAILED", "mpv init failed");
        return;
      }
      ApplyDecode();
      result->Success(EncodableValue(EncodableMap{
          {EncodableValue("ok"), EncodableValue(true)},
          {EncodableValue("ready"), EncodableValue(true)},
      }));
      return;
    }
    if (method == "open") {
      IngestDecodeArgs(args);
      if (!EnsureMpv()) {
        result->Error("OPEN_FAILED", "mpv init failed");
        return;
      }
      ApplyDecode();
      if (args) {
        auto pit = args->find(EncodableValue("props"));
        if (pit != args->end()) {
          if (const auto* props = std::get_if<EncodableMap>(&pit->second)) {
            for (const auto& kv : *props) {
              const auto* k = std::get_if<std::string>(&kv.first);
              if (!k) continue;
              std::string v;
              if (const auto* s = std::get_if<std::string>(&kv.second))
                v = *s;
              else if (const auto* b = std::get_if<bool>(&kv.second))
                v = *b ? "yes" : "no";
              else if (const auto* i = std::get_if<int32_t>(&kv.second))
                v = std::to_string(*i);
              else if (const auto* d = std::get_if<double>(&kv.second))
                v = std::to_string(*d);
              if (!v.empty()) mpv_set_property_string(mpv_, k->c_str(), v.c_str());
            }
          }
        }
        auto hit = args->find(EncodableValue("headers"));
        if (hit != args->end()) {
          if (const auto* headers = std::get_if<EncodableMap>(&hit->second)) {
            std::string fields;
            for (const auto& kv : *headers) {
              const auto* k = std::get_if<std::string>(&kv.first);
              const auto* v = std::get_if<std::string>(&kv.second);
              if (!k || !v) continue;
              if (!fields.empty()) fields += "\r\n";
              fields += *k + ": " + *v;
            }
            if (!fields.empty())
              mpv_set_property_string(mpv_, "http-header-fields", fields.c_str());
          }
        }
      }
      ShowWindow(hwnd_, SW_HIDE);
      const std::string url = ArgString(args, "url");
      const int64_t start = ArgInt64(args, "startAtMs");
      // replace 即可换片；勿 stop（打断无缝换集）。
      if (start > 0) {
        char start_opt[64];
        snprintf(start_opt, sizeof(start_opt), "start=%.3f", start / 1000.0);
        Command({"loadfile", url, "replace", start_opt});
      } else {
        Command({"loadfile", url, "replace"});
      }
      Command({"set", "pause", "no"});
      result->Success();
      return;
    }
    if (method == "play") {
      Command({"set", "pause", "no"});
      result->Success();
      return;
    }
    if (method == "pause") {
      Command({"set", "pause", "yes"});
      result->Success();
      return;
    }
    if (method == "stop") {
      Command({"stop"});
      ShowWindow(hwnd_, SW_HIDE);
      result->Success();
      return;
    }
    if (method == "dispose") {
      Destroy();
      result->Success();
      return;
    }
    if (method == "seek") {
      char sec[64];
      snprintf(sec, sizeof(sec), "%.3f", ArgInt64(args, "positionMs") / 1000.0);
      Command({"seek", sec, "absolute"});
      result->Success();
      return;
    }
    if (method == "setVolume") {
      char v[32];
      snprintf(v, sizeof(v), "%g", ArgDouble(args, "volume", 100));
      if (mpv_) mpv_set_property_string(mpv_, "volume", v);
      result->Success();
      return;
    }
    if (method == "setRate") {
      char v[32];
      snprintf(v, sizeof(v), "%g", ArgDouble(args, "rate", 1));
      if (mpv_) mpv_set_property_string(mpv_, "speed", v);
      result->Success();
      return;
    }
    if (method == "setDecode" || method == "setOpts") {
      IngestDecodeArgs(args);
      ApplyDecode();
      result->Success();
      return;
    }
    if (method == "setVisible") {
      visible_ = ArgBool(args, "visible");
      if (hwnd_) ShowWindow(hwnd_, visible_ ? SW_SHOWNOACTIVATE : SW_HIDE);
      result->Success();
      return;
    }
    if (method == "updateFrame" || method == "setVideoRect") {
      if (hwnd_ && args) {
        const double x = ArgDouble(args, "x");
        const double y = ArgDouble(args, "y");
        const double w = ArgDouble(args, "w", ArgDouble(args, "width"));
        const double h = ArgDouble(args, "h", ArgDouble(args, "height"));
        if (w > 1 && h > 1) {
          // Dart localToGlobal：相对 Flutter 视图的逻辑像素（不是 Win32 屏幕坐标）。
          // 子 HWND 用物理像素；勿 ScreenToClient（会把视图坐标误当屏幕坐标缩到一角）。
          HWND parent = FlutterHwnd();
          double dpr = 1.0;
          if (parent) {
            HDC dc = GetDC(parent);
            if (dc) {
              dpr = GetDeviceCaps(dc, LOGPIXELSX) / 96.0;
              ReleaseDC(parent, dc);
            }
          }
          if (dpr <= 0) dpr = 1.0;
          const int cx = static_cast<int>(std::lround(x * dpr));
          const int cy = static_cast<int>(std::lround(y * dpr));
          const int cw = std::max(1, static_cast<int>(std::lround(w * dpr)));
          const int ch = std::max(1, static_cast<int>(std::lround(h * dpr)));
          MoveWindow(hwnd_, cx, cy, cw, ch, TRUE);
          // Win7：抬升进程内播控/弹幕子窗，避免被视频 HWND 压住。
          if (parent) {
            auto raise_class = [parent](const wchar_t* cls) {
              HWND child = nullptr;
              while ((child = FindWindowExW(parent, child, cls, nullptr)) != nullptr) {
                SetWindowPos(child, HWND_TOP, 0, 0, 0, 0,
                             SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
              }
            };
            raise_class(L"KotvWinChromeDanmaku");
            raise_class(L"KotvWinChromePanel");
          }
        }
      }
      result->Success();
      return;
    }
    if (method == "videoInfo") {
      result->Success(EncodableValue(VideoInfo()));
      return;
    }
    if (method == "setAspect" || method == "setRepeatOne" || method == "setAudioOffsetMs" ||
        method == "setEqualizer" || method == "setAudioTrack" || method == "setVideoTrack" ||
        method == "setSubtitleTrack" || method == "setSecondarySubtitleTrack" ||
        method == "setSubtitleOffsetMs" || method == "setSubtitleStyle" ||
        method == "addSubtitle" || method == "setRenderMode" ||
        method == "setSurfaceLayerEnabled" || method == "setDiscTitle" ||
        method == "setDiscChapter" || method == "openDiscMenu" || method == "retryVideo") {
      result->Success();
      return;
    }
    if (method == "getAudioTracks" || method == "getVideoTracks" ||
        method == "getSubtitleTracks") {
      result->Success(EncodableValue("[]"));
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
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> events_;
  std::mutex sink_mu_;
  std::unique_ptr<flutter::EventSink<EncodableValue>> sink_;

  mpv_handle* mpv_ = nullptr;
  HWND hwnd_ = nullptr;
  std::thread event_thread_;
  std::atomic<bool> stop_events_{false};
  std::string decode_mode_ = "auto";
  std::string hwdec_;
  bool direct_ = false;
  bool visible_ = false;
};

}  // namespace

void KotvMpvPluginRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  KotvMpvPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
