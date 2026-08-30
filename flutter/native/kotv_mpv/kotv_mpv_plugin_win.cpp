#include "kotv_mpv_plugin.h"

#include "kotv_mpv_desktop_core.h"
#include "kotv_mpv_lib_path.h"

#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/texture_registrar.h>

#include <atomic>
#include <chrono>
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

class KotvMpvPixelBuffer {
 public:
  explicit KotvMpvPixelBuffer(flutter::TextureRegistrar* registrar)
      : registrar_(registrar) {
    pixels_.assign(1280 * 720 * 4, 0);
    texture_ = std::make_unique<flutter::TextureVariant>(flutter::PixelBufferTexture(
        [this](size_t width, size_t height) { return CopyBuffer(width, height); }));
    texture_id_ = registrar_->RegisterTexture(texture_.get());
  }

  ~KotvMpvPixelBuffer() {
    if (texture_id_ >= 0 && registrar_) {
      registrar_->UnregisterTexture(texture_id_);
    }
  }

  int64_t texture_id() const { return texture_id_; }

  void MarkFrame() {
    if (texture_id_ >= 0 && registrar_) {
      registrar_->MarkTextureFrameAvailable(texture_id_);
    }
  }

 private:
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

 public:
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
  flutter::TextureRegistrar* registrar_;
  std::unique_ptr<flutter::TextureVariant> texture_;
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
    registrar_ = engine->texture_registrar();
    auto messenger = engine->messenger();
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
      uint8_t frame[1920 * 1080 * 4];
      while (tick_running_) {
        kotv_mpv_desktop_tick();
        if (kotv_mpv_desktop_is_ready()) {
          int w = 0;
          int h = 0;
          if (kotv_mpv_desktop_take_frame(frame, static_cast<int>(sizeof(frame)), &w, &h)) {
            if (pixel_buffer_) {
              pixel_buffer_->UpdateFrame(frame, w, h);
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
      if (!pixel_buffer_ && registrar_) {
        pixel_buffer_ = std::make_unique<KotvMpvPixelBuffer>(registrar_);
      }
      char* lib = kotv_find_libmpv_path();
      if (!lib) {
        result->Error("NO_LIBMPV", "libmpv not found; run scripts/fetch-desktop-mpv-libs.sh", nullptr);
        return;
      }
      const int rc = kotv_mpv_desktop_init(lib);
      free(lib);
      if (rc != 0) {
        result->Error("CREATE_FAILED", "libmpv load failed", nullptr);
        return;
      }
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
      result->Success(flutter::EncodableValue(false));
      return;
    }

    if (method == "open") {
      std::string url;
      std::string hwdec = "auto";
      int live = 0;
      std::string headers;
      if (args) {
        if (auto* v = std::get_if<std::string>(&(*args)[flutter::EncodableValue("url")])) url = *v;
        if (auto* v = std::get_if<std::string>(&(*args)[flutter::EncodableValue("decode")])) hwdec = *v;
        if (auto* v = std::get_if<bool>(&(*args)[flutter::EncodableValue("live")])) live = *v ? 1 : 0;
        if (auto* h = std::get_if<flutter::EncodableMap>(&(*args)[flutter::EncodableValue("headers")])) {
          headers = HeadersToMultiline(h);
        }
      }
      const int rc = kotv_mpv_desktop_open(url.c_str(), headers.c_str(), hwdec.c_str(), 0, 0, live);
      if (rc < 0) {
        result->Error("OPEN_FAILED", "mpv open failed", nullptr);
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
        if (auto* v = std::get_if<int32_t>(&(*args)[flutter::EncodableValue("positionMs")])) ms = *v;
        if (auto* v = std::get_if<int64_t>(&(*args)[flutter::EncodableValue("positionMs")])) ms = *v;
      }
      kotv_mpv_desktop_seek_ms(ms);
      result->Success();
      return;
    }
    if (method == "setVolume") {
      int vol = 80;
      if (args) {
        if (auto* v = std::get_if<double>(&(*args)[flutter::EncodableValue("volume")])) vol = static_cast<int>(*v);
        if (auto* v = std::get_if<int32_t>(&(*args)[flutter::EncodableValue("volume")])) vol = *v;
      }
      kotv_mpv_desktop_set_volume(vol);
      result->Success();
      return;
    }
    if (method == "setRate") {
      double rate = 1.0;
      if (args) {
        if (auto* v = std::get_if<double>(&(*args)[flutter::EncodableValue("rate")])) rate = *v;
      }
      kotv_mpv_desktop_set_rate(rate);
      result->Success();
      return;
    }
    if (method == "setProperty") {
      std::string key;
      std::string value;
      if (args) {
        if (auto* v = std::get_if<std::string>(&(*args)[flutter::EncodableValue("key")])) key = *v;
        if (auto* v = std::get_if<std::string>(&(*args)[flutter::EncodableValue("value")])) value = *v;
      }
      kotv_mpv_desktop_set_prop(key.c_str(), value.c_str());
      result->Success();
      return;
    }
    if (method == "dispose") {
      kotv_mpv_desktop_stop();
      kotv_mpv_desktop_shutdown();
      StopTick();
      pixel_buffer_.reset();
      result->Success();
      return;
    }

    result->NotImplemented();
  }

  flutter::TextureRegistrar* registrar_ = nullptr;
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
