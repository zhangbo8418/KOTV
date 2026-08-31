#include "kotv_mpv_plugin.h"

#include "kotv_mpv_desktop_core.h"
#include "kotv_mpv_lib_path.h"

#include "../../../internal/player/embed/mpv_shim.h"

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

class KotvMpvPluginWin {
 public:
  static KotvMpvPluginWin& Instance() {
    static KotvMpvPluginWin inst;
    return inst;
  }

  void Register(flutter::FlutterEngine* engine) {
    FlutterDesktopPluginRegistrarRef native = engine->GetRegistrarForPlugin("kotv_mpv");
    tex_reg_ = FlutterDesktopRegistrarGetTextureRegistrar(native);
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

  ~KotvMpvPluginWin() { StopTick(); kotv_mpv_desktop_shutdown(); }

  void StartTick() {
    if (tick_running_.exchange(true)) return;
    tick_thread_ = std::thread([this] {
      std::vector<uint8_t> frame(1920 * 1080 * 4);
      while (tick_running_) {
        kotv_mpv_desktop_tick();
        if (kotv_mpv_desktop_is_ready()) {
          int w = 0;
          int h = 0;
          if (kotv_mpv_desktop_take_frame(frame.data(), static_cast<int>(frame.size()), &w, &h)) {
            if (pixel_buffer_) {
              pixel_buffer_->UpdateFrame(frame.data(), w, h);
              pixel_buffer_->MarkFrame();
            }
          }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
      }
    });
  }

  void StopTick() {
    if (!tick_running_.exchange(false)) return;
    if (tick_thread_.joinable()) tick_thread_.join();
  }

  void HandleMethod(const flutter::MethodCall<flutter::EncodableValue>& call,
                    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    const std::string& method = call.method_name();
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());

    if (method == "create") {
      if (!pixel_buffer_ && tex_reg_) {
        pixel_buffer_ = std::make_unique<KotvMpvPixelBuffer>(tex_reg_);
      }
      std::string hwdec = "auto";
      int gpu_next = 0;
      int vulkan = 0;
      if (args) {
        if (auto* v = MapGet<std::string>(*args, "decode")) hwdec = *v;
        if (auto* v = MapGet<bool>(*args, "gpuNext")) gpu_next = *v ? 1 : 0;
        if (auto* v = MapGet<bool>(*args, "vulkan")) vulkan = *v ? 1 : 0;
      }
      char* lib = kotv_find_libmpv_path();
      if (!lib) {
        result->Error("NO_LIBMPV", "libmpv not found; put mpv-2.dll next to kotv.exe", nullptr);
        return;
      }
      kotv_mpv_set_preinit_options(gpu_next, vulkan, hwdec.c_str());
      int rc = kotv_mpv_desktop_init(lib);
      int used_gn = gpu_next;
      int used_vk = vulkan;
      if (rc != 0 && (gpu_next || vulkan)) {
        kotv_mpv_set_preinit_options(0, 0, hwdec.c_str());
        rc = kotv_mpv_desktop_init(lib);
        used_gn = 0;
        used_vk = 0;
      }
      if (rc != 0) {
        char msg[448];
        const unsigned long winerr = kotv_mpv_last_load_error();
        snprintf(msg, sizeof(msg), "libmpv load failed (rc=%d winerr=%lu path=%s)", rc, winerr,
                 lib ? lib : "");
        free(lib);
        result->Error("CREATE_FAILED", msg, nullptr);
        return;
      }
      free(lib);
      kotv_mpv_desktop_note_opts(used_gn, used_vk);
      StartTick();
      flutter::EncodableMap out;
      out[flutter::EncodableValue("ok")] = flutter::EncodableValue(true);
      out[flutter::EncodableValue("ready")] = flutter::EncodableValue(true);
      if (pixel_buffer_) {
        out[flutter::EncodableValue("textureId")] = flutter::EncodableValue(pixel_buffer_->texture_id());
      }
      result->Success(flutter::EncodableValue(out));
      return;
    }

    if (method == "isVulkanAvailable") {
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
            snprintf(msg, sizeof(msg),
                     "mpv open failed (LoadLibrary winerr=%lu)", winerr);
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
      // 只停播，不 FreeLibrary：Dart dispose 是异步的，卸库会与下一次 create/open 抢跑。
      kotv_mpv_desktop_release();
      StopTick();
      result->Success();
      return;
    }

    result->NotImplemented();
  }

  FlutterDesktopTextureRegistrarRef tex_reg_ = nullptr;
  std::unique_ptr<KotvMpvPixelBuffer> pixel_buffer_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> method_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> event_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;
  std::thread tick_thread_;
  std::atomic<bool> tick_running_{false};
};

}  // namespace

void RegisterKotvMpvPlugin(flutter::FlutterEngine* engine) {
  KotvMpvPluginWin::Instance().Register(engine);
}
