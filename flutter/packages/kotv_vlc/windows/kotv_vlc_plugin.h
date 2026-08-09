#ifndef KOTV_VLC_PLUGIN_H_
#define KOTV_VLC_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/texture_registrar.h>

#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace kotv_vlc {

class KotvVlcPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  KotvVlcPlugin(flutter::PluginRegistrarWindows* registrar);
  virtual ~KotvVlcPlugin();

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  int64_t CreateTexture();
  bool Load(const std::string& lib_dir, const std::string& plugin_dir,
            std::string* err);
  bool Play(const std::string& url, const std::vector<std::string>& headers,
            std::string* err);
  void Stop();
  void DisposePlayer();
  void StartPump();
  void StopPump();
  // Flutter 3.24+：CopyBufferCallback 为 (size_t width, size_t height)，非指针 out 参数。
  const FlutterDesktopPixelBuffer* CopyPixelBuffer(size_t width, size_t height);

  flutter::PluginRegistrarWindows* registrar_;
  flutter::TextureRegistrar* textures_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  std::unique_ptr<flutter::TextureVariant> texture_;
  int64_t texture_id_ = -1;
  bool ready_ = false;

  std::mutex frame_mu_;
  std::vector<uint8_t> frame_rgba_;
  int frame_w_ = 0;
  int frame_h_ = 0;
  FlutterDesktopPixelBuffer pixel_buffer_{};

  std::atomic<bool> pump_running_{false};
  std::thread pump_;
};

}  // namespace kotv_vlc

#endif  // KOTV_VLC_PLUGIN_H_
