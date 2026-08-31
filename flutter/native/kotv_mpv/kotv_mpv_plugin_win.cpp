#include "kotv_mpv_plugin.h"

#include "kotv_mpv_desktop_core.h"
#include "kotv_mpv_lib_path.h"
#include "kotv_mpv_win_surface.h"

#include "../../../internal/player/embed/mpv_shim.h"

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <flutter_windows.h>
#endif

#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter_plugin_registrar.h>
#include <flutter_texture_registrar.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

std::string HeadersToMultiline(const flutter::EncodableMap* headers) {
  if (!headers) return {};
  std::string out;
  for (const auto& e : *headers) {
    const auto* k = std::get_if<std::string>(&e.first);
    const auto* v = std::get_if<std::string>(&e.second);
    if (!k || !v || k->empty()) continue;
    out += *k + ": " + *v + "\r\n";
  }
  return out;
}

template <typename T>
const T* MapGet(const flutter::EncodableMap& m, const char* key) {
  const auto it = m.find(flutter::EncodableValue(std::string(key)));
  if (it == m.end()) return nullptr;
  return std::get_if<T>(&it->second);
}

#if defined(_WIN32)
bool KotvIsWindows7() {
  // 不用 GetVersionExW（MSVC C4996 当错误）；RtlGetVersion 不受清单兼容层影响。
  using RtlGetVersionFn = LONG(WINAPI*)(OSVERSIONINFOW*);
  HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
  if (!ntdll) return false;
  auto rtl = reinterpret_cast<RtlGetVersionFn>(GetProcAddress(ntdll, "RtlGetVersion"));
  if (!rtl) return false;
  OSVERSIONINFOW vi{};
  vi.dwOSVersionInfoSize = sizeof(vi);
  if (rtl(&vi) != 0) return false;
  return vi.dwMajorVersion == 6 && vi.dwMinorVersion == 1;
}

void ApplyWin7MpvOpts(std::string* hwdec, int* gpu_next, int* vulkan) {
  if (!KotvIsWindows7()) return;
  if (gpu_next) *gpu_next = 0;
  if (vulkan) *vulkan = 0;
  if (hwdec && *hwdec == "d3d11va") *hwdec = "dxva2";
}
#endif

class KotvMpvPixelBuffer {
 public:
  explicit KotvMpvPixelBuffer(FlutterDesktopTextureRegistrarRef registrar)
      : registrar_(registrar) {
    pixels_.assign(1280 * 720 * 4, 0);
    FlutterDesktopTextureInfo info{};
    info.type = kFlutterDesktopPixelBufferTexture;
    info.pixel_buffer_config.callback = &KotvMpvPixelBuffer::OnCopy;
    info.pixel_buffer_config.user_data = this;
    texture_id_ = FlutterDesktopTextureRegistrarRegisterExternalTexture(registrar_, &info);
  }

  ~KotvMpvPixelBuffer() {
    if (texture_id_ >= 0 && registrar_) {
      FlutterDesktopTextureRegistrarUnregisterExternalTexture(registrar_, texture_id_, nullptr,
                                                              nullptr);
    }
  }

  int64_t texture_id() const { return texture_id_; }

  void MarkFrame() {
    if (texture_id_ >= 0 && registrar_) {
      FlutterDesktopTextureRegistrarMarkExternalTextureFrameAvailable(registrar_, texture_id_);
    }
  }

  void UpdateFrame(const uint8_t* src, int w, int h) {
    if (!src || w <= 0 || h <= 0) return;
    const size_t need = static_cast<size_t>(w) * static_cast<size_t>(h) * 4;
    std::lock_guard<std::mutex> lock(mu_);
    if (pixels_.size() < need) pixels_.resize(need);
    std::memcpy(pixels_.data(), src, need);
    frame_w_ = w;
    frame_h_ = h;
  }

 private:
  static const FlutterDesktopPixelBuffer* OnCopy(size_t width, size_t height, void* user) {
    return static_cast<KotvMpvPixelBuffer*>(user)->CopyBuffer(width, height);
  }

  const FlutterDesktopPixelBuffer* CopyBuffer(size_t width, size_t height) {
    (void)width;
    (void)height;
    std::lock_guard<std::mutex> lock(mu_);
    if (frame_w_ <= 0 || frame_h_ <= 0 || pixels_.empty()) return nullptr;
    pixel_buffer_.buffer = pixels_.data();
    pixel_buffer_.width = static_cast<size_t>(frame_w_);
    pixel_buffer_.height = static_cast<size_t>(frame_h_);
    return &pixel_buffer_;
  }

  FlutterDesktopTextureRegistrarRef registrar_ = nullptr;
  int64_t texture_id_ = -1;
  std::mutex mu_;
  std::vector<uint8_t> pixels_;
  FlutterDesktopPixelBuffer pixel_buffer_{};
  int frame_w_ = 0;
  int frame_h_ = 0;
};

struct PendingOpen {
  bool active = false;
  std::string url;
  std::string headers;
  std::string hwdec = "auto";
  int gpu_next = 0;
  int vulkan = 0;
  int live = 0;
  flutter::EncodableMap props;
};

class KotvMpvPluginWin {
 public:
  static KotvMpvPluginWin& Instance() {
    static KotvMpvPluginWin inst;
    return inst;
  }

  void Register(flutter::FlutterEngine* engine) {
    FlutterDesktopPluginRegistrarRef native = engine->GetRegistrarForPlugin("kotv_mpv");
    registrar_ = native;
    tex_reg_ = FlutterDesktopRegistrarGetTextureRegistrar(native);
#if defined(_WIN32)
    if (FlutterDesktopViewRef view = FlutterDesktopPluginRegistrarGetView(native)) {
      parent_hwnd_ = FlutterDesktopViewGetHWND(view);
    }
    // 与 runner 一致：用 monitor DPI（Flutter 3.19 / Win7 可用）。
    dpi_scale_ = 1.0;
    if (parent_hwnd_) {
      HMONITOR monitor = MonitorFromWindow(parent_hwnd_, MONITOR_DEFAULTTONEAREST);
      const UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
      if (dpi > 0) dpi_scale_ = static_cast<double>(dpi) / 96.0;
    }
#endif
    auto* messenger = engine->messenger();
    method_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        messenger, "kotv_mpv", &flutter::StandardMethodCodec::GetInstance());
    method_channel_->SetMethodCallHandler(
        [this](const auto& call, auto result) { HandleMethod(call, std::move(result)); });

    event_channel_ = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
        messenger, "kotv_mpv/events", &flutter::StandardMethodCodec::GetInstance());
    event_channel_->SetStreamHandler(
        std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
            [this](const flutter::EncodableValue*, std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& sink) {
              event_sink_ = std::move(sink);
              return nullptr;
            },
            [this](const flutter::EncodableValue*) {
              event_sink_.reset();
              return nullptr;
            }));
  }

 private:
  KotvMpvPluginWin() {
    kotv_mpv_desktop_set_event_cb(
        [](const char* json, void* user) {
          auto* self = static_cast<KotvMpvPluginWin*>(user);
          if (self && self->event_sink_ && json) {
            self->event_sink_->Success(flutter::EncodableValue(json));
          }
        },
        this);
  }

  ~KotvMpvPluginWin() {
    StopTick();
    surface_.Destroy();
    kotv_mpv_desktop_shutdown();
  }

  void StartTick() {
    if (tick_running_.exchange(true)) return;
    tick_thread_ = std::thread([this] {
      std::vector<uint8_t> frame(1920 * 1080 * 4);
      while (tick_running_) {
        kotv_mpv_desktop_tick();
        if (!hard_render_ && kotv_mpv_desktop_is_ready()) {
          int w = 0;
          int h = 0;
          if (kotv_mpv_desktop_take_frame(frame.data(), static_cast<int>(frame.size()), &w, &h)) {
            if (pixel_buffer_) {
              pixel_buffer_->UpdateFrame(frame.data(), w, h);
              pixel_buffer_->MarkFrame();
            }
          }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(hard_render_ ? 200 : 300));
      }
    });
  }

  void StopTick() {
    if (!tick_running_.exchange(false)) return;
    if (tick_thread_.joinable()) tick_thread_.join();
  }

#if defined(_WIN32)
  bool AttachHardSurface(int x, int y, int w, int h) {
    if (!parent_hwnd_) return false;
    POINT origin{0, 0};
    ClientToScreen(parent_hwnd_, &origin);
    const int rx = x - static_cast<int>(origin.x);
    const int ry = y - static_cast<int>(origin.y);
    if (!surface_.Ensure(parent_hwnd_)) return false;
    surface_.SetBounds(rx, ry, w, h);
    if (kotv_mpv_desktop_hard_active()) return true;
    const int rc = kotv_mpv_desktop_set_hard_win(static_cast<long long>(reinterpret_cast<intptr_t>(surface_.Hwnd())));
    if (rc != 0) return false;
    StartTick();
    return true;
  }

  void ProcessPendingOpen() {
    if (!pending_.active) return;
    if (hard_render_ && !kotv_mpv_desktop_hard_active()) return;
    PendingOpen p = pending_;
    pending_.active = false;
    const int rc = kotv_mpv_desktop_open(p.url.c_str(), p.headers.c_str(), p.hwdec.c_str(), p.gpu_next,
                                         p.vulkan, p.live);
    if (rc >= 0) {
      for (const auto& e : p.props) {
        const auto* k = std::get_if<std::string>(&e.first);
        const auto* v = std::get_if<std::string>(&e.second);
        if (k && v) kotv_mpv_desktop_set_prop(k->c_str(), v->c_str());
      }
    }
  }

  int ScalePx(double v) const {
    if (v <= 0.0) return 0;
    return static_cast<int>(v * dpi_scale_ + 0.5);
  }
#endif

  void HandleMethod(const flutter::MethodCall<flutter::EncodableValue>& call,
                    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    const std::string& method = call.method_name();
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());

    if (method == "create") {
      std::string render = "surface";
      std::string hwdec = "auto";
      int gpu_next = 0;
      int vulkan = 0;
      if (args) {
        if (auto* v = MapGet<std::string>(*args, "render")) render = *v;
        if (auto* v = MapGet<std::string>(*args, "decode")) hwdec = *v;
        if (auto* v = MapGet<bool>(*args, "gpuNext")) gpu_next = *v ? 1 : 0;
        if (auto* v = MapGet<bool>(*args, "vulkan")) vulkan = *v ? 1 : 0;
      }
#if defined(_WIN32)
      ApplyWin7MpvOpts(&hwdec, &gpu_next, &vulkan);
      hard_render_ = (render != "texture");
#endif
      char* lib = kotv_find_libmpv_path();
      if (!lib) {
        result->Error("NO_LIBMPV", "libmpv not found; put mpv-2.dll next to kotv.exe", nullptr);
        return;
      }
      kotv_mpv_set_preinit_options(gpu_next, vulkan, hwdec.c_str());
      int rc = 0;
      int used_gn = gpu_next;
      int used_vk = vulkan;
#if defined(_WIN32)
      if (hard_render_) {
        rc = kotv_mpv_desktop_ensure_lib(lib);
      } else {
        if (!pixel_buffer_ && tex_reg_) {
          pixel_buffer_ = std::make_unique<KotvMpvPixelBuffer>(tex_reg_);
        }
        rc = kotv_mpv_desktop_init(lib);
      }
#else
      if (!pixel_buffer_ && tex_reg_) {
        pixel_buffer_ = std::make_unique<KotvMpvPixelBuffer>(tex_reg_);
      }
      rc = kotv_mpv_desktop_init(lib);
#endif
      if (rc != 0 && (gpu_next || vulkan)) {
        kotv_mpv_set_preinit_options(0, 0, hwdec.c_str());
#if defined(_WIN32)
        rc = hard_render_ ? kotv_mpv_desktop_ensure_lib(lib) : kotv_mpv_desktop_init(lib);
#else
        rc = kotv_mpv_desktop_init(lib);
#endif
        used_gn = 0;
        used_vk = 0;
      }
      if (rc != 0) {
        char msg[512];
        const unsigned long winerr = kotv_mpv_last_load_error();
        const char* detail = kotv_mpv_last_load_detail();
        if (detail && detail[0]) {
          snprintf(msg, sizeof(msg), "libmpv load failed (rc=%d winerr=%lu path=%s; %s)", rc, winerr,
                   lib ? lib : "", detail);
        } else {
          snprintf(msg, sizeof(msg), "libmpv load failed (rc=%d winerr=%lu path=%s)", rc, winerr,
                   lib ? lib : "");
        }
        free(lib);
        result->Error("CREATE_FAILED", msg, nullptr);
        return;
      }
      free(lib);
      kotv_mpv_desktop_note_opts(used_gn, used_vk);
#if defined(_WIN32)
      if (!hard_render_) {
        StartTick();
      }
#else
      StartTick();
#endif
      flutter::EncodableMap out;
      out[flutter::EncodableValue("ok")] = flutter::EncodableValue(true);
      out[flutter::EncodableValue("ready")] = flutter::EncodableValue(true);
#if defined(_WIN32)
      out[flutter::EncodableValue("hardRender")] = flutter::EncodableValue(hard_render_);
#endif
      if (pixel_buffer_) {
        out[flutter::EncodableValue("textureId")] = flutter::EncodableValue(pixel_buffer_->texture_id());
      }
      result->Success(flutter::EncodableValue(out));
      return;
    }

#if defined(_WIN32)
    if (method == "updateSurfaceBounds") {
      double x = 0;
      double y = 0;
      double w = 0;
      double h = 0;
      if (args) {
        if (auto* v = MapGet<double>(*args, "x")) x = *v;
        if (auto* v = MapGet<int32_t>(*args, "x")) x = static_cast<double>(*v);
        if (auto* v = MapGet<double>(*args, "y")) y = *v;
        if (auto* v = MapGet<int32_t>(*args, "y")) y = static_cast<double>(*v);
        if (auto* v = MapGet<double>(*args, "width")) w = *v;
        if (auto* v = MapGet<int32_t>(*args, "width")) w = static_cast<double>(*v);
        if (auto* v = MapGet<double>(*args, "height")) h = *v;
        if (auto* v = MapGet<int32_t>(*args, "height")) h = static_cast<double>(*v);
      }
      if (!hard_render_) {
        result->Success();
        return;
      }
      if (w <= 0 || h <= 0) {
        result->Success();
        return;
      }
      if (!AttachHardSurface(ScalePx(x), ScalePx(y), ScalePx(w), ScalePx(h))) {
        result->Error("SURFACE_FAILED", "HWND hard render attach failed", nullptr);
        return;
      }
      ProcessPendingOpen();
      result->Success();
      return;
    }
#endif

    if (method == "isVulkanAvailable") {
#if defined(_WIN32)
      if (KotvIsWindows7()) {
        result->Success(flutter::EncodableValue(false));
        return;
      }
#endif
      result->Success(flutter::EncodableValue(kotv_mpv_desktop_is_vulkan_available()));
      return;
    }

    if (method == "getAudioTracks") {
      char* json = kotv_mpv_desktop_get_audio_tracks_json();
      if (!json) {
        result->Success(flutter::EncodableValue("[]"));
      } else {
        result->Success(flutter::EncodableValue(std::string(json)));
        kotv_mpv_free_str(json);
      }
      return;
    }

    if (method == "open") {
      std::string url;
      std::string hwdec = "auto";
      int live = 0;
      int gpu_next = 0;
      int vulkan = 0;
      std::string headers;
      if (args) {
        if (auto* v = MapGet<std::string>(*args, "url")) url = *v;
        if (auto* v = MapGet<std::string>(*args, "decode")) hwdec = *v;
        if (auto* v = MapGet<bool>(*args, "live")) live = *v ? 1 : 0;
        if (auto* v = MapGet<bool>(*args, "gpuNext")) gpu_next = *v ? 1 : 0;
        if (auto* v = MapGet<bool>(*args, "vulkan")) vulkan = *v ? 1 : 0;
        if (auto* h = MapGet<flutter::EncodableMap>(*args, "headers")) {
          headers = HeadersToMultiline(h);
        }
      }
#if defined(_WIN32)
      ApplyWin7MpvOpts(&hwdec, &gpu_next, &vulkan);
      if (hard_render_ && !kotv_mpv_desktop_hard_active()) {
        pending_.active = true;
        pending_.url = url;
        pending_.headers = headers;
        pending_.hwdec = hwdec;
        pending_.gpu_next = gpu_next;
        pending_.vulkan = vulkan;
        pending_.live = live;
        pending_.props = flutter::EncodableMap{};
        if (args) {
          if (auto* props = MapGet<flutter::EncodableMap>(*args, "props")) {
            pending_.props = *props;
          }
        }
        result->Success();
        return;
      }
#endif
      const int rc = kotv_mpv_desktop_open(url.c_str(), headers.c_str(), hwdec.c_str(), gpu_next, vulkan, live);
      if (rc < 0) {
        char msg[160];
        if (rc == -21) {
          snprintf(msg, sizeof(msg), "mpv open failed (empty url)");
        } else if (rc == -20) {
          snprintf(msg, sizeof(msg), "mpv open failed (not loaded)");
        } else if (rc == -2) {
          const unsigned long winerr = kotv_mpv_last_load_error();
          if (winerr != 0) {
            snprintf(msg, sizeof(msg), "mpv open failed (LoadLibrary winerr=%lu)", winerr);
          } else {
            snprintf(msg, sizeof(msg), "mpv open failed (rc=-2, DLL/bind)");
          }
        } else if (rc == -5) {
          snprintf(msg, sizeof(msg), "mpv open failed (initialize rc=-5)");
        } else if (rc == -6) {
          snprintf(msg, sizeof(msg), "mpv open failed (sw render rc=-6)");
        } else if (rc == -1) {
          snprintf(msg, sizeof(msg), "mpv open failed (event queue full)");
        } else {
          snprintf(msg, sizeof(msg), "mpv open failed (rc=%d)", rc);
        }
        result->Error("OPEN_FAILED", msg, nullptr);
      } else {
        if (args) {
          if (auto* props = MapGet<flutter::EncodableMap>(*args, "props")) {
            for (const auto& e : *props) {
              const auto* k = std::get_if<std::string>(&e.first);
              const auto* v = std::get_if<std::string>(&e.second);
              if (k && v) kotv_mpv_desktop_set_prop(k->c_str(), v->c_str());
            }
          }
        }
        result->Success();
      }
      return;
    }

    if (method == "setRenderMode") {
      std::string mode = "surface";
      if (args) {
        if (auto* v = MapGet<std::string>(*args, "mode")) mode = *v;
      }
#if defined(_WIN32)
      const bool want_hard = (mode != "texture");
      if (want_hard != hard_render_) {
        hard_render_ = want_hard;
        pending_.active = false;
        if (hard_render_) {
          if (pixel_buffer_) pixel_buffer_.reset();
          if (surface_.Hwnd()) {
            kotv_mpv_desktop_set_hard_win(static_cast<long long>(reinterpret_cast<intptr_t>(surface_.Hwnd())));
          } else {
            kotv_mpv_desktop_set_hard_win(0);
          }
        } else {
          surface_.Destroy();
          kotv_mpv_desktop_set_hard_win(0);
          if (!pixel_buffer_ && tex_reg_) {
            pixel_buffer_ = std::make_unique<KotvMpvPixelBuffer>(tex_reg_);
          }
          StartTick();
        }
      }
#endif
      result->Success();
      return;
    }

    if (method == "setOpts") {
      int gpu_next = 0;
      int vulkan = 0;
      std::string hwdec = "auto";
      if (args) {
        if (auto* v = MapGet<bool>(*args, "gpuNext")) gpu_next = *v ? 1 : 0;
        if (auto* v = MapGet<bool>(*args, "vulkan")) vulkan = *v ? 1 : 0;
        if (auto* v = MapGet<std::string>(*args, "decode")) hwdec = *v;
#if defined(_WIN32)
        ApplyWin7MpvOpts(&hwdec, &gpu_next, &vulkan);
#endif
        kotv_mpv_set_preinit_options(gpu_next, vulkan, hwdec.c_str());
        kotv_mpv_desktop_note_opts(gpu_next, vulkan);
        if (auto* props = MapGet<flutter::EncodableMap>(*args, "props")) {
          for (const auto& e : *props) {
            const auto* k = std::get_if<std::string>(&e.first);
            const auto* v = std::get_if<std::string>(&e.second);
            if (k && v) kotv_mpv_desktop_set_prop(k->c_str(), v->c_str());
          }
        }
      }
      if (hwdec.size()) kotv_mpv_desktop_set_prop("hwdec", hwdec.c_str());
      result->Success();
      return;
    }

    if (method == "setDecode") {
      std::string hwdec = "auto";
      if (args) {
        if (auto* v = MapGet<std::string>(*args, "decode")) hwdec = *v;
      }
#if defined(_WIN32)
      ApplyWin7MpvOpts(&hwdec, nullptr, nullptr);
#endif
      kotv_mpv_desktop_set_prop("hwdec", hwdec.c_str());
      result->Success();
      return;
    }

    if (method == "setAudioTrack") {
      std::string id;
      if (args) {
        if (auto* v = MapGet<std::string>(*args, "id")) id = *v;
      }
      kotv_mpv_desktop_set_audio_track(id.c_str());
      result->Success();
      return;
    }

    if (method == "setSubtitleTrack") {
      std::string id;
      if (args) {
        if (auto* v = MapGet<std::string>(*args, "id")) id = *v;
      }
      kotv_mpv_desktop_set_subtitle_track(id.c_str());
      result->Success();
      return;
    }

    if (method == "retryVideo") {
      const int rc = kotv_mpv_desktop_retry_video();
      if (rc < 0) {
        result->Error("RETRY_FAILED", "mpv retry failed", nullptr);
      } else {
        result->Success();
      }
      return;
    }

    if (method == "play") {
      kotv_mpv_desktop_pause(0);
      result->Success();
      return;
    }
    if (method == "pause") {
      kotv_mpv_desktop_pause(1);
      result->Success();
      return;
    }
    if (method == "stop") {
      kotv_mpv_desktop_stop();
      result->Success();
      return;
    }
    if (method == "seek") {
      int64_t ms = 0;
      if (args) {
        if (auto* v = MapGet<int32_t>(*args, "positionMs")) ms = *v;
        if (auto* v = MapGet<int64_t>(*args, "positionMs")) ms = *v;
        if (auto* v = MapGet<double>(*args, "positionMs")) ms = static_cast<int64_t>(*v);
      }
      kotv_mpv_desktop_seek_ms(ms);
      result->Success();
      return;
    }
    if (method == "setVolume") {
      int vol = 80;
      if (args) {
        if (auto* v = MapGet<double>(*args, "volume")) vol = static_cast<int>(*v);
        if (auto* v = MapGet<int32_t>(*args, "volume")) vol = *v;
        if (auto* v = MapGet<int64_t>(*args, "volume")) vol = static_cast<int>(*v);
      }
      kotv_mpv_desktop_set_volume(vol);
      result->Success();
      return;
    }
    if (method == "setRate") {
      double rate = 1.0;
      if (args) {
        if (auto* v = MapGet<double>(*args, "rate")) rate = *v;
      }
      kotv_mpv_desktop_set_rate(rate);
      result->Success();
      return;
    }
    if (method == "setProperty") {
      std::string key;
      std::string value;
      if (args) {
        if (auto* v = MapGet<std::string>(*args, "key")) key = *v;
        if (auto* v = MapGet<std::string>(*args, "value")) value = *v;
      }
      kotv_mpv_desktop_set_prop(key.c_str(), value.c_str());
      result->Success();
      return;
    }
    if (method == "dispose") {
      pending_.active = false;
      kotv_mpv_desktop_release();
      StopTick();
#if defined(_WIN32)
      surface_.Destroy();
#endif
      result->Success();
      return;
    }

    result->NotImplemented();
  }

  FlutterDesktopPluginRegistrarRef registrar_ = nullptr;
  FlutterDesktopTextureRegistrarRef tex_reg_ = nullptr;
  std::unique_ptr<KotvMpvPixelBuffer> pixel_buffer_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> method_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> event_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;
  std::thread tick_thread_;
  std::atomic<bool> tick_running_{false};
#if defined(_WIN32)
  HWND parent_hwnd_ = nullptr;
  double dpi_scale_ = 1.0;
  bool hard_render_ = true;
  KotvMpvWinSurface surface_;
  PendingOpen pending_;
#endif
};

}  // namespace

void RegisterKotvMpvPlugin(flutter::FlutterEngine* engine) {
  KotvMpvPluginWin::Instance().Register(engine);
}
