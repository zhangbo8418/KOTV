#include "kotv_vlc_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <chrono>
#include <cstdint>
#include <cstring>

extern "C" {
#include "../common/vlc_shim.h"
}

namespace kotv_vlc {

void KotvVlcPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<KotvVlcPlugin>(registrar);
  registrar->AddPlugin(std::move(plugin));
}

KotvVlcPlugin::KotvVlcPlugin(flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar), textures_(registrar->texture_registrar()) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "kotv_vlc",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
  frame_rgba_.resize(0);
}

KotvVlcPlugin::~KotvVlcPlugin() { DisposePlayer(); }

void KotvVlcPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* args =
      std::get_if<flutter::EncodableMap>(method_call.arguments());
  auto arg_string = [&](const char* key) -> std::string {
    if (!args) return {};
    auto it = args->find(flutter::EncodableValue(key));
    if (it == args->end()) return {};
    if (const auto* s = std::get_if<std::string>(&it->second)) return *s;
    return {};
  };
  auto arg_int = [&](const char* key, int64_t def = 0) -> int64_t {
    if (!args) return def;
    auto it = args->find(flutter::EncodableValue(key));
    if (it == args->end()) return def;
    if (const auto* i = std::get_if<int32_t>(&it->second)) return *i;
    if (const auto* i = std::get_if<int64_t>(&it->second)) return *i;
    if (const auto* d = std::get_if<double>(&it->second)) return (int64_t)*d;
    return def;
  };
  auto arg_double = [&](const char* key, double def = 0) -> double {
    if (!args) return def;
    auto it = args->find(flutter::EncodableValue(key));
    if (it == args->end()) return def;
    if (const auto* d = std::get_if<double>(&it->second)) return *d;
    if (const auto* i = std::get_if<int32_t>(&it->second)) return *i;
    if (const auto* i = std::get_if<int64_t>(&it->second)) return (double)*i;
    return def;
  };
  auto arg_bool = [&](const char* key) -> bool {
    if (!args) return false;
    auto it = args->find(flutter::EncodableValue(key));
    if (it == args->end()) return false;
    if (const auto* b = std::get_if<bool>(&it->second)) return *b;
    return false;
  };

  const auto& method = method_call.method_name();
  if (method == "create") {
    // 复用已有 texture / libvlc：勿每集 Dispose+FreeLibrary（Win 起播/关应用崩主因）。
    Stop();
    if (texture_id_ < 0) {
      CreateTexture();
    }
    flutter::EncodableMap out;
    out[flutter::EncodableValue("textureId")] =
        flutter::EncodableValue(texture_id_);
    result->Success(flutter::EncodableValue(out));
    return;
  }
  if (method == "load") {
    std::string err;
    if (!Load(arg_string("libDir"), arg_string("pluginDir"), &err)) {
      result->Error("load", err);
      return;
    }
    result->Success();
    return;
  }
  if (method == "play") {
    std::string err;
    std::vector<std::string> headers;
    if (args) {
      auto it = args->find(flutter::EncodableValue("headers"));
      if (it != args->end()) {
        if (const auto* hm = std::get_if<flutter::EncodableMap>(&it->second)) {
          for (const auto& kv : *hm) {
            const auto* k = std::get_if<std::string>(&kv.first);
            if (!k || k->empty()) continue;
            std::string v;
            if (const auto* s = std::get_if<std::string>(&kv.second)) {
              v = *s;
            } else {
              continue;
            }
            if (v.empty()) continue;
            headers.push_back(*k + ": " + v);
          }
        }
      }
    }
    if (!Play(arg_string("url"), headers, &err)) {
      result->Error("play", err);
      return;
    }
    result->Success();
    return;
  }
  if (method == "stop") {
    Stop();
    result->Success();
    return;
  }
  if (method == "pause") {
    kotv_vlc_pause(1);
    result->Success();
    return;
  }
  if (method == "resume") {
    kotv_vlc_pause(0);
    result->Success();
    return;
  }
  if (method == "toggle") {
    const bool playing = kotv_vlc_is_playing() != 0;
    kotv_vlc_pause(playing ? 1 : 0);
    flutter::EncodableMap out;
    out[flutter::EncodableValue("playing")] =
        flutter::EncodableValue(!playing);
    result->Success(flutter::EncodableValue(out));
    return;
  }
  if (method == "seek") {
    const int64_t ms = arg_int("ms");
    kotv_vlc_set_time(ms);
    result->Success();
    return;
  }
  if (method == "volume") {
    kotv_vlc_set_volume((int)arg_int("value", 80));
    result->Success();
    return;
  }
  if (method == "rate") {
    kotv_vlc_set_rate((float)arg_double("value", 1.0));
    result->Success();
    return;
  }
  if (method == "decode") {
    std::string mode = arg_string("mode");
    if (mode.empty()) {
      mode = arg_bool("soft") ? "soft" : "hard";
    }
    if (mode == "soft")
      kotv_vlc_set_decode(1);
    else if (mode == "hard")
      kotv_vlc_set_decode(0);
    else
      kotv_vlc_set_decode(-1);
    result->Success();
    return;
  }
  if (method == "repeat") {
    kotv_vlc_set_repeat(arg_bool("on") ? 1 : 0);
    result->Success();
    return;
  }
  if (method == "tracks") {
    const int type = (int)arg_int("type", 0);
    char buf[8192];
    const int n = kotv_vlc_track_list(type, buf, (int)sizeof(buf));
    flutter::EncodableList tracks;
    if (n > 0) {
      std::string raw(buf);
      size_t start = 0;
      while (start < raw.size()) {
        size_t nl = raw.find('\n', start);
        if (nl == std::string::npos) nl = raw.size();
        std::string line = raw.substr(start, nl - start);
        start = nl + 1;
        if (line.empty()) continue;
        size_t tab = line.find('\t');
        flutter::EncodableMap row;
        if (tab == std::string::npos) {
          row[flutter::EncodableValue("id")] = flutter::EncodableValue(line);
          row[flutter::EncodableValue("name")] = flutter::EncodableValue(line);
        } else {
          row[flutter::EncodableValue("id")] =
              flutter::EncodableValue(line.substr(0, tab));
          row[flutter::EncodableValue("name")] =
              flutter::EncodableValue(line.substr(tab + 1));
        }
        tracks.push_back(flutter::EncodableValue(row));
      }
    }
    flutter::EncodableMap out;
    out[flutter::EncodableValue("tracks")] = flutter::EncodableValue(tracks);
    out[flutter::EncodableValue("current")] =
        flutter::EncodableValue((int64_t)kotv_vlc_get_track(type));
    out[flutter::EncodableValue("count")] = flutter::EncodableValue(n < 0 ? 0 : n);
    result->Success(flutter::EncodableValue(out));
    return;
  }
  if (method == "setTrack") {
    const int type = (int)arg_int("type", 0);
    const int id = (int)arg_int("id", -1);
    const int rc = kotv_vlc_set_track(type, id);
    if (rc < 0) {
      result->Error("setTrack", "set track failed");
      return;
    }
    result->Success();
    return;
  }
  if (method == "status") {
    int w = 0, h = 0;
    {
      std::lock_guard<std::mutex> lock(frame_mu_);
      w = frame_w_;
      h = frame_h_;
    }
    int vw = 0, vh = 0;
    if (kotv_vlc_video_size(&vw, &vh) == 0 && vw > 0 && vh > 0) {
      w = vw;
      h = vh;
    }
    flutter::EncodableMap out;
    out[flutter::EncodableValue("playing")] =
        flutter::EncodableValue(kotv_vlc_is_playing() != 0);
    out[flutter::EncodableValue("positionMs")] =
        flutter::EncodableValue((int64_t)kotv_vlc_get_time());
    out[flutter::EncodableValue("durationMs")] =
        flutter::EncodableValue((int64_t)kotv_vlc_get_length());
    out[flutter::EncodableValue("bufferedMs")] =
        flutter::EncodableValue((int64_t)kotv_vlc_get_buffered());
    out[flutter::EncodableValue("buffering")] =
        flutter::EncodableValue(kotv_vlc_is_buffering() != 0);
    out[flutter::EncodableValue("speedBps")] =
        flutter::EncodableValue((int64_t)kotv_vlc_get_speed_bps());
    out[flutter::EncodableValue("width")] = flutter::EncodableValue(w);
    out[flutter::EncodableValue("height")] = flutter::EncodableValue(h);
    out[flutter::EncodableValue("rate")] =
        flutter::EncodableValue((double)kotv_vlc_get_rate());
    out[flutter::EncodableValue("textureId")] =
        flutter::EncodableValue(texture_id_);
    result->Success(flutter::EncodableValue(out));
    return;
  }
  if (method == "dispose") {
    DisposePlayer(/*unload=*/false);
    result->Success();
    return;
  }
  if (method == "shutdown") {
    /* 关进程：只静音停播，禁止 FreeLibrary（与 exit/atexit 叠在一起必崩）。 */
    QuietShutdown();
    result->Success();
    return;
  }
  result->NotImplemented();
}

int64_t KotvVlcPlugin::CreateTexture() {
  flutter::PixelBufferTexture::CopyBufferCallback cb =
      [this](size_t width, size_t height) -> const FlutterDesktopPixelBuffer* {
        return CopyPixelBuffer(width, height);
      };
  texture_ = std::make_unique<flutter::TextureVariant>(flutter::PixelBufferTexture(std::move(cb)));
  texture_id_ = textures_->RegisterTexture(texture_.get());
  return texture_id_;
}

bool KotvVlcPlugin::Load(const std::string& lib_dir,
                         const std::string& plugin_dir, std::string* err) {
  const int rc = kotv_vlc_load(lib_dir.c_str(), plugin_dir.c_str());
  if (rc != 0) {
    if (err) *err = "libvlc load failed (" + std::to_string(rc) + ")";
    return false;
  }
  ready_ = true;
  return true;
}

bool KotvVlcPlugin::Play(const std::string& url,
                         const std::vector<std::string>& headers,
                         std::string* err) {
  if (!ready_) {
    if (err) *err = "libvlc not loaded";
    return false;
  }
  std::vector<const char*> lines;
  lines.reserve(headers.size());
  for (const auto& h : headers) {
    lines.push_back(h.c_str());
  }
  const int rc = kotv_vlc_play_with_headers(
      url.c_str(), lines.empty() ? nullptr : lines.data(),
      static_cast<int>(lines.size()));
  if (rc != 0) {
    if (err) *err = "vlc play failed (" + std::to_string(rc) + ")";
    return false;
  }
  StartPump();
  return true;
}

void KotvVlcPlugin::Stop() {
  StopPump();
  kotv_vlc_stop();
}

void KotvVlcPlugin::QuietShutdown() {
  StopPump();
  /* 只 mute/stop，不 release instance、不 FreeLibrary */
  kotv_vlc_stop();
}

void KotvVlcPlugin::DisposePlayer(bool unload) {
  StopPump();
  kotv_vlc_stop();
  if (unload) {
    kotv_vlc_unload();
    ready_ = false;
  }
  if (texture_id_ >= 0 && textures_) {
    textures_->UnregisterTexture(texture_id_);
    texture_id_ = -1;
  }
  texture_.reset();
}

void KotvVlcPlugin::StartPump() {
  if (pump_running_.exchange(true)) return;
  pump_ = std::thread([this]() {
    std::vector<uint8_t> tmp;  // 按实际分辨率动态扩容（含 8K）
    while (pump_running_) {
      int pw = 0, ph = 0;
      int64_t pseq = 0;
      if (kotv_vlc_peek_frame(&pw, &ph, &pseq) && pw > 1 && ph > 1) {
        const size_t need = (size_t)pw * (size_t)ph * 4;
        if (tmp.size() < need) tmp.resize(need);
      } else if (tmp.empty()) {
        tmp.resize(1280ull * 720ull * 4);
      }
      int w = 0, h = 0;
      int ok = kotv_vlc_take_frame(tmp.data(), (int)tmp.size(), &w, &h);
      if (!ok && w > 1 && h > 1) {
        const size_t need = (size_t)w * (size_t)h * 4;
        if (tmp.size() < need) tmp.resize(need);
        ok = kotv_vlc_take_frame(tmp.data(), (int)tmp.size(), &w, &h);
      }
      if (ok && w > 1 && h > 1) {
        const size_t bytes = (size_t)w * (size_t)h * 4;
        {
          std::lock_guard<std::mutex> lock(frame_mu_);
          frame_rgba_.resize(bytes);
          // display_cb 已转成 RGBA，此处直接拷贝。
          memcpy(frame_rgba_.data(), tmp.data(), bytes);
          frame_w_ = w;
          frame_h_ = h;
        }
        if (texture_id_ >= 0 && textures_) {
          textures_->MarkTextureFrameAvailable(texture_id_);
        }
        // 有新帧尽快再取，冲高帧率；无帧时短睡降 CPU
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
      } else {
        std::this_thread::sleep_for(std::chrono::milliseconds(4));
      }
    }
  });
}

void KotvVlcPlugin::StopPump() {
  if (!pump_running_.exchange(false)) return;
  if (pump_.joinable()) pump_.join();
}

const FlutterDesktopPixelBuffer* KotvVlcPlugin::CopyPixelBuffer(size_t /*width*/,
                                                                size_t /*height*/) {
  std::lock_guard<std::mutex> lock(frame_mu_);
  if (frame_w_ < 2 || frame_h_ < 2 || frame_rgba_.empty()) {
    return nullptr;
  }
  pixel_buffer_.buffer = frame_rgba_.data();
  pixel_buffer_.width = (size_t)frame_w_;
  pixel_buffer_.height = (size_t)frame_h_;
  return &pixel_buffer_;
}

}  // namespace kotv_vlc
