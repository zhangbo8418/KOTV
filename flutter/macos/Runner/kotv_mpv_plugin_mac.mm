#import <FlutterMacOS/FlutterMacOS.h>
#import <CoreVideo/CoreVideo.h>

#include <atomic>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "../../native/kotv_mpv/kotv_mpv_desktop_core.h"
#include "../../native/kotv_mpv/kotv_mpv_lib_path.h"
#include "../../../internal/player/embed/mpv_shim.h"

@interface KotvMpvMacTexture : NSObject <FlutterTexture>
@property(nonatomic, assign) int64_t textureId;
@property(nonatomic, weak) id<FlutterTextureRegistry> registry;
@end

@implementation KotvMpvMacTexture {
  std::mutex _mu;
  std::vector<uint8_t> _pixels;
  int _w;
  int _h;
}

- (instancetype)initWithRegistry:(id<FlutterTextureRegistry>)registry {
  self = [super init];
  if (self) {
    _registry = registry;
    _textureId = [registry registerTexture:self];
    _w = 0;
    _h = 0;
  }
  return self;
}

- (void)dealloc {
  if (_textureId >= 0 && _registry) {
    [_registry unregisterTexture:_textureId];
  }
}

- (void)updateRGBA:(const uint8_t*)src width:(int)w height:(int)h {
  if (!src || w <= 0 || h <= 0) return;
  const size_t need = (size_t)w * (size_t)h * 4;
  std::lock_guard<std::mutex> lock(_mu);
  if (_pixels.size() < need) _pixels.resize(need);
  std::memcpy(_pixels.data(), src, need);
  _w = w;
  _h = h;
  [_registry textureFrameAvailable:_textureId];
}

- (CVPixelBufferRef)copyPixelBuffer {
  std::lock_guard<std::mutex> lock(_mu);
  if (_w <= 0 || _h <= 0 || _pixels.empty()) return nil;
  CVPixelBufferRef px = nil;
  NSDictionary* attrs = @{
    (NSString*)kCVPixelBufferIOSurfacePropertiesKey : @{},
  };
  CVReturn rc = CVPixelBufferCreate(
      kCFAllocatorDefault, _w, _h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &px);
  if (rc != kCVReturnSuccess || !px) return nil;
  CVPixelBufferLockBaseAddress(px, 0);
  uint8_t* dst = (uint8_t*)CVPixelBufferGetBaseAddress(px);
  const size_t stride = CVPixelBufferGetBytesPerRow(px);
  for (int y = 0; y < _h; ++y) {
    const uint8_t* row = _pixels.data() + (size_t)y * (size_t)_w * 4;
    uint8_t* out = dst + y * stride;
    for (int x = 0; x < _w; ++x) {
      const uint8_t r = row[x * 4 + 0];
      const uint8_t g = row[x * 4 + 1];
      const uint8_t b = row[x * 4 + 2];
      out[x * 4 + 0] = b;
      out[x * 4 + 1] = g;
      out[x * 4 + 2] = r;
      out[x * 4 + 3] = 255;
    }
  }
  CVPixelBufferUnlockBaseAddress(px, 0);
  return px;
}

@end

@interface KotvMpvStreamHandler : NSObject <FlutterStreamHandler>
@property(nonatomic, copy) FlutterEventSink sink;
@end

@implementation KotvMpvStreamHandler
- (FlutterError*)onListenWithArguments:(id)arguments eventSink:(FlutterEventSink)events {
  self.sink = events;
  kotv_mpv_desktop_set_event_cb(
      [](const char* json, void* user) {
        KotvMpvStreamHandler* h = (__bridge KotvMpvStreamHandler*)user;
        if (!h.sink || !json) return;
        NSString* s = [NSString stringWithUTF8String:json];
        h.sink(s);
      },
      (__bridge void*)self);
  return nil;
}
- (FlutterError*)onCancelWithArguments:(id)arguments {
  self.sink = nil;
  return nil;
}
@end

namespace {

FlutterMethodChannel* g_method = nil;
FlutterEventChannel* g_events = nil;
NSObject<FlutterStreamHandler>* g_stream_handler = nil;
id<FlutterTextureRegistry> g_tex_registry = nil;
KotvMpvMacTexture* g_texture = nil;
std::thread g_tick;
std::atomic<bool> g_tick_running{false};

void StartTick() {
  if (g_tick_running.exchange(true)) return;
  g_tick = std::thread([] {
    std::vector<uint8_t> frame(1920 * 1080 * 4);
    while (g_tick_running) {
      kotv_mpv_desktop_tick();
      if (kotv_mpv_desktop_is_ready() && g_texture) {
        int w = 0;
        int h = 0;
        if (kotv_mpv_desktop_take_frame(frame.data(), static_cast<int>(frame.size()), &w, &h)) {
          const size_t need = static_cast<size_t>(w) * static_cast<size_t>(h) * 4;
          auto pixels = std::make_shared<std::vector<uint8_t>>(frame.begin(), frame.begin() + need);
          const int cw = w;
          const int ch = h;
          dispatch_async(dispatch_get_main_queue(), ^{
            [g_texture updateRGBA:pixels->data() width:cw height:ch];
          });
        }
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(300));
    }
  });
}

void StopTick() {
  if (!g_tick_running.exchange(false)) return;
  if (g_tick.joinable()) g_tick.join();
}

static NSString* HeadersToMultiline(NSDictionary* headers) {
  if (!headers) return @"";
  NSMutableString* out = [NSMutableString string];
  for (NSString* k in headers) {
    id v = headers[k];
    if (![v isKindOfClass:[NSString class]]) continue;
    [out appendFormat:@"%@: %@\r\n", k, (NSString*)v];
  }
  return out;
}

static void HandleMethod(FlutterMethodCall* call, FlutterResult result) {
  NSString* method = call.method;
  NSDictionary* args = [call.arguments isKindOfClass:[NSDictionary class]] ? call.arguments : @{};

  if ([method isEqualToString:@"create"]) {
    if (!g_texture && g_tex_registry) {
      g_texture = [[KotvMpvMacTexture alloc] initWithRegistry:g_tex_registry];
    }
    char* lib = kotv_find_libmpv_path();
    if (!lib) {
      result([FlutterError errorWithCode:@"NO_LIBMPV"
                                 message:@"libmpv not found; put libmpv.dylib in Contents/Frameworks"
                                 details:nil]);
      return;
    }
    int rc = kotv_mpv_desktop_init(lib);
    free(lib);
    if (rc != 0) {
      result([FlutterError errorWithCode:@"CREATE_FAILED" message:@"load failed" details:nil]);
      return;
    }
    StartTick();
    result(@{@"ok" : @YES, @"ready" : @YES, @"textureId" : @(g_texture.textureId)});
    return;
  }
  if ([method isEqualToString:@"isVulkanAvailable"]) {
    result(@(kotv_mpv_desktop_is_vulkan_available()));
    return;
  }
  if ([method isEqualToString:@"getAudioTracks"]) {
    char* json = kotv_mpv_desktop_get_audio_tracks_json();
    if (!json) {
      result(@"[]");
    } else {
      result([NSString stringWithUTF8String:json]);
      kotv_mpv_free_str(json);
    }
    return;
  }
  if ([method isEqualToString:@"open"]) {
    NSString* url = args[@"url"] ?: @"";
    NSString* hwdec = args[@"decode"] ?: @"auto";
    BOOL live = [args[@"live"] boolValue];
    BOOL gpuNext = [args[@"gpuNext"] boolValue];
    BOOL vulkan = [args[@"vulkan"] boolValue];
    NSString* headers = HeadersToMultiline(args[@"headers"]);
    int rc = kotv_mpv_desktop_open(url.UTF8String, headers.UTF8String, hwdec.UTF8String,
                                   gpuNext ? 1 : 0, vulkan ? 1 : 0, live ? 1 : 0);
    if (rc < 0) {
      result([FlutterError errorWithCode:@"OPEN_FAILED"
                                 message:[NSString stringWithFormat:@"mpv open failed (rc=%d)", rc]
                                 details:nil]);
    } else {
      NSDictionary* props = [args[@"props"] isKindOfClass:[NSDictionary class]] ? args[@"props"] : nil;
      for (NSString* k in props) {
        id v = props[k];
        if (![k isKindOfClass:[NSString class]] || ![v isKindOfClass:[NSString class]]) continue;
        kotv_mpv_desktop_set_prop(k.UTF8String, ((NSString*)v).UTF8String);
      }
      result(nil);
    }
    return;
  }
  if ([method isEqualToString:@"setOpts"]) {
    BOOL gpuNext = [args[@"gpuNext"] boolValue];
    BOOL vulkan = [args[@"vulkan"] boolValue];
    NSString* hwdec = args[@"decode"] ?: @"auto";
    kotv_mpv_set_preinit_options(gpuNext ? 1 : 0, vulkan ? 1 : 0, hwdec.UTF8String);
    kotv_mpv_desktop_note_opts(gpuNext ? 1 : 0, vulkan ? 1 : 0);
    NSDictionary* props = [args[@"props"] isKindOfClass:[NSDictionary class]] ? args[@"props"] : nil;
    for (NSString* k in props) {
      id v = props[k];
      if (![k isKindOfClass:[NSString class]] || ![v isKindOfClass:[NSString class]]) continue;
      kotv_mpv_desktop_set_prop(k.UTF8String, ((NSString*)v).UTF8String);
    }
    kotv_mpv_desktop_set_prop("hwdec", hwdec.UTF8String);
    result(nil);
    return;
  }
  if ([method isEqualToString:@"setDecode"]) {
    NSString* hwdec = args[@"decode"] ?: @"auto";
    kotv_mpv_desktop_set_prop("hwdec", hwdec.UTF8String);
    result(nil);
    return;
  }
  if ([method isEqualToString:@"setAudioTrack"]) {
    NSString* tid = args[@"id"] ?: @"";
    kotv_mpv_desktop_set_audio_track(tid.UTF8String);
    result(nil);
    return;
  }
  if ([method isEqualToString:@"setSubtitleTrack"]) {
    NSString* tid = args[@"id"] ?: @"";
    kotv_mpv_desktop_set_subtitle_track(tid.UTF8String);
    result(nil);
    return;
  }
  if ([method isEqualToString:@"retryVideo"]) {
    int rc = kotv_mpv_desktop_retry_video();
    if (rc < 0) {
      result([FlutterError errorWithCode:@"RETRY_FAILED" message:@"mpv retry failed" details:nil]);
    } else {
      result(nil);
    }
    return;
  }
  if ([method isEqualToString:@"play"]) {
    kotv_mpv_desktop_pause(0);
    result(nil);
    return;
  }
  if ([method isEqualToString:@"pause"]) {
    kotv_mpv_desktop_pause(1);
    result(nil);
    return;
  }
  if ([method isEqualToString:@"stop"]) {
    kotv_mpv_desktop_stop();
    result(nil);
    return;
  }
  if ([method isEqualToString:@"seek"]) {
    NSNumber* ms = args[@"positionMs"] ?: @0;
    kotv_mpv_desktop_seek_ms(ms.longLongValue);
    result(nil);
    return;
  }
  if ([method isEqualToString:@"setVolume"]) {
    NSNumber* vol = args[@"volume"] ?: @80;
    kotv_mpv_desktop_set_volume(vol.intValue);
    result(nil);
    return;
  }
  if ([method isEqualToString:@"setRate"]) {
    NSNumber* rate = args[@"rate"] ?: @1;
    kotv_mpv_desktop_set_rate(rate.doubleValue);
    result(nil);
    return;
  }
  if ([method isEqualToString:@"setProperty"]) {
    NSString* key = args[@"key"] ?: @"";
    NSString* val = args[@"value"] ?: @"";
    kotv_mpv_desktop_set_prop(key.UTF8String, val.UTF8String);
    result(nil);
    return;
  }
  if ([method isEqualToString:@"dispose"]) {
    kotv_mpv_desktop_release();
    StopTick();
    result(nil);
    return;
  }
  result(FlutterMethodNotImplemented);
}

}  // namespace

extern "C" void kotv_mpv_plugin_register_macos(FlutterEngine* engine) {
  NSObject<FlutterPluginRegistrar>* reg = [engine registrarForPlugin:@"KotvMpvPlugin"];
  g_tex_registry = [reg textures];
  g_method = [FlutterMethodChannel methodChannelWithName:@"kotv_mpv"
                                         binaryMessenger:engine.binaryMessenger
                                                   codec:[FlutterStandardMethodCodec sharedInstance]];
  [g_method setMethodCallHandler:^(FlutterMethodCall* call, FlutterResult result) {
    HandleMethod(call, result);
  }];
  g_stream_handler = [KotvMpvStreamHandler new];
  g_events = [FlutterEventChannel eventChannelWithName:@"kotv_mpv/events"
                                       binaryMessenger:engine.binaryMessenger
                                                 codec:[FlutterStandardMethodCodec sharedInstance]];
  [g_events setStreamHandler:g_stream_handler];
}
