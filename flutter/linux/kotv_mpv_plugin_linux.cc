// Linux kotv_mpv plugin（对齐 Flutter 3.44 Linux C API）。
#include <flutter_linux/flutter_linux.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "../native/kotv_mpv/kotv_mpv_desktop_core.h"
#include "../native/kotv_mpv/kotv_mpv_lib_path.h"

#include "../../../internal/player/embed/mpv_shim.h"

struct KotvTexState {
  FlTextureRegistrar* registrar = nullptr;
  FlPixelBufferTexture* texture = nullptr;
  int64_t texture_id = -1;
  std::mutex mu;
  std::vector<uint8_t> pixels;
  int w = 0;
  int h = 0;
};

static KotvTexState g_tex;
static FlMethodChannel* g_method = nullptr;
static FlEventChannel* g_events = nullptr;
static std::atomic<bool> g_events_listen{false};
static std::thread g_tick;
static std::atomic<bool> g_tick_running{false};

typedef struct _KotvMpvTexture KotvMpvTexture;
typedef struct _KotvMpvTextureClass KotvMpvTextureClass;
struct _KotvMpvTexture {
  FlPixelBufferTexture parent_instance;
};
struct _KotvMpvTextureClass {
  FlPixelBufferTextureClass parent_class;
};
static void kotv_mpv_texture_class_init(KotvMpvTextureClass* klass);
static void kotv_mpv_texture_init(KotvMpvTexture* self);
G_DEFINE_TYPE(KotvMpvTexture, kotv_mpv_texture, fl_pixel_buffer_texture_get_type())

static gboolean kotv_mpv_texture_copy_pixels(FlPixelBufferTexture* /*texture*/, const uint8_t** buffer,
                                             uint32_t* width, uint32_t* height, GError** /*error*/) {
  std::lock_guard<std::mutex> lock(g_tex.mu);
  if (g_tex.w <= 0 || g_tex.h <= 0 || g_tex.pixels.empty()) {
    *buffer = nullptr;
    *width = 0;
    *height = 0;
    return TRUE;
  }
  *buffer = g_tex.pixels.data();
  *width = static_cast<uint32_t>(g_tex.w);
  *height = static_cast<uint32_t>(g_tex.h);
  return TRUE;
}

static void kotv_mpv_texture_class_init(KotvMpvTextureClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels = kotv_mpv_texture_copy_pixels;
}

static void kotv_mpv_texture_init(KotvMpvTexture* /*self*/) {}

static FlValue* map_get(FlValue* map, const char* key) {
  if (!map || !key || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) return nullptr;
  return fl_value_lookup_string(map, key);
}

static const char* map_str(FlValue* map, const char* key) {
  FlValue* v = map_get(map, key);
  if (!v || fl_value_get_type(v) != FL_VALUE_TYPE_STRING) return nullptr;
  return fl_value_get_string(v);
}

static void EmitEvent(const char* json) {
  if (!g_events_listen.load() || !g_events || !json) return;
  g_autoptr(FlValue) msg = fl_value_new_string(json);
  g_autoptr(GError) err = nullptr;
  fl_event_channel_send(g_events, msg, nullptr, &err);
}

static void StartTick() {
  if (g_tick_running.exchange(true)) return;
  kotv_mpv_desktop_set_event_cb([](const char* json, void*) { EmitEvent(json); }, nullptr);
  g_tick = std::thread([] {
    uint8_t frame[1920 * 1080 * 4];
    while (g_tick_running) {
      kotv_mpv_desktop_tick();
      if (kotv_mpv_desktop_is_ready() && g_tex.registrar && g_tex.texture) {
        int w = 0;
        int h = 0;
        if (kotv_mpv_desktop_take_frame(frame, (int)sizeof(frame), &w, &h)) {
          const size_t need = (size_t)w * (size_t)h * 4;
          {
            std::lock_guard<std::mutex> lock(g_tex.mu);
            if (g_tex.pixels.size() < need) g_tex.pixels.resize(need);
            std::memcpy(g_tex.pixels.data(), frame, need);
            g_tex.w = w;
            g_tex.h = h;
          }
          fl_texture_registrar_mark_texture_frame_available(g_tex.registrar, FL_TEXTURE(g_tex.texture));
        }
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(300));
    }
  });
}

static void StopTick() {
  if (!g_tick_running.exchange(false)) return;
  if (g_tick.joinable()) g_tick.join();
}

static std::string HeadersToMultiline(FlValue* headers) {
  std::string out;
  if (!headers || fl_value_get_type(headers) != FL_VALUE_TYPE_MAP) return out;
  const size_t n = fl_value_get_length(headers);
  for (size_t i = 0; i < n; ++i) {
    FlValue* k = fl_value_get_map_key(headers, i);
    FlValue* v = fl_value_get_map_value(headers, i);
    if (!k || !v) continue;
    if (fl_value_get_type(k) != FL_VALUE_TYPE_STRING || fl_value_get_type(v) != FL_VALUE_TYPE_STRING) continue;
    out += fl_value_get_string(k);
    out += ": ";
    out += fl_value_get_string(v);
    out += "\r\n";
  }
  return out;
}

static void EnsureTexture(FlTextureRegistrar* registrar) {
  if (g_tex.texture) return;
  g_tex.registrar = registrar;
  g_tex.texture = FL_PIXEL_BUFFER_TEXTURE(g_object_new(kotv_mpv_texture_get_type(), nullptr));
  fl_texture_registrar_register_texture(registrar, FL_TEXTURE(g_tex.texture));
  g_tex.texture_id = fl_texture_get_id(FL_TEXTURE(g_tex.texture));
}

static void kotv_mpv_method_call(FlMethodChannel* /*channel*/, FlMethodCall* method_call, gpointer user_data) {
  FlView* view = FL_VIEW(user_data);
  FlEngine* engine = fl_view_get_engine(view);
  FlTextureRegistrar* tex_reg = fl_engine_get_texture_registrar(engine);
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (strcmp(method, "create") == 0) {
    EnsureTexture(tex_reg);
    char* lib = kotv_find_libmpv_path();
    if (!lib) {
      response = FL_METHOD_RESPONSE(
          fl_method_error_response_new("NO_LIBMPV", "libmpv not found; put libmpv.so.2 in lib/ next to the binary", nullptr));
    } else {
      const int rc = kotv_mpv_desktop_init(lib);
      free(lib);
      if (rc != 0) {
        response = FL_METHOD_RESPONSE(fl_method_error_response_new("CREATE_FAILED", "load failed", nullptr));
      } else {
        StartTick();
        g_autoptr(FlValue) result = fl_value_new_map();
        fl_value_set_string_take(result, "ok", fl_value_new_bool(true));
        fl_value_set_string_take(result, "ready", fl_value_new_bool(true));
        fl_value_set_string_take(result, "textureId", fl_value_new_int(g_tex.texture_id));
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
      }
    }
  } else if (strcmp(method, "isVulkanAvailable") == 0) {
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(
        fl_value_new_bool(kotv_mpv_desktop_is_vulkan_available())));
  } else if (strcmp(method, "getAudioTracks") == 0) {
    char* json = kotv_mpv_desktop_get_audio_tracks_json();
    if (!json) {
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_string("[]")));
    } else {
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_string(json)));
      kotv_mpv_free_str(json);
    }
  } else if (strcmp(method, "open") == 0) {
    const char* url = map_str(args, "url");
    const char* hwdec = map_str(args, "decode");
    FlValue* live_val = map_get(args, "live");
    const bool live = live_val && fl_value_get_type(live_val) == FL_VALUE_TYPE_BOOL && fl_value_get_bool(live_val);
    FlValue* gpu_next_val = map_get(args, "gpuNext");
    FlValue* vulkan_val = map_get(args, "vulkan");
    const bool gpu_next = gpu_next_val && fl_value_get_type(gpu_next_val) == FL_VALUE_TYPE_BOOL &&
                          fl_value_get_bool(gpu_next_val);
    const bool vulkan = vulkan_val && fl_value_get_type(vulkan_val) == FL_VALUE_TYPE_BOOL &&
                        fl_value_get_bool(vulkan_val);
    FlValue* headers = map_get(args, "headers");
    const std::string h = HeadersToMultiline(headers);
    const int rc = kotv_mpv_desktop_open(url ? url : "", h.c_str(), hwdec ? hwdec : "auto",
                                         gpu_next ? 1 : 0, vulkan ? 1 : 0, live ? 1 : 0);
    char msg[64];
    snprintf(msg, sizeof(msg), "mpv open failed (rc=%d)", rc);
    response = rc < 0 ? FL_METHOD_RESPONSE(fl_method_error_response_new("OPEN_FAILED", msg, nullptr))
                      : FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "play") == 0) {
    kotv_mpv_desktop_pause(0);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "pause") == 0) {
    kotv_mpv_desktop_pause(1);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "stop") == 0) {
    kotv_mpv_desktop_stop();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "seek") == 0) {
    FlValue* ms_val = map_get(args, "positionMs");
    int64_t ms = 0;
    if (ms_val && fl_value_get_type(ms_val) == FL_VALUE_TYPE_INT) {
      ms = fl_value_get_int(ms_val);
    }
    kotv_mpv_desktop_seek_ms(ms);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "setVolume") == 0) {
    FlValue* vol_val = map_get(args, "volume");
    int vol = 80;
    if (vol_val) {
      if (fl_value_get_type(vol_val) == FL_VALUE_TYPE_FLOAT) {
        vol = static_cast<int>(fl_value_get_float(vol_val));
      } else if (fl_value_get_type(vol_val) == FL_VALUE_TYPE_INT) {
        vol = static_cast<int>(fl_value_get_int(vol_val));
      }
    }
    kotv_mpv_desktop_set_volume(vol);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "setRate") == 0) {
    FlValue* rate_val = map_get(args, "rate");
    double rate = 1.0;
    if (rate_val && fl_value_get_type(rate_val) == FL_VALUE_TYPE_FLOAT) {
      rate = fl_value_get_float(rate_val);
    }
    kotv_mpv_desktop_set_rate(rate);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "setProperty") == 0) {
    const char* key = map_str(args, "key");
    const char* val = map_str(args, "value");
    if (key && val) {
      kotv_mpv_desktop_set_prop(key, val);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "setDecode") == 0) {
    const char* hwdec = map_str(args, "decode");
    if (hwdec) {
      kotv_mpv_desktop_set_prop("hwdec", hwdec);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "dispose") == 0) {
    kotv_mpv_desktop_stop();
    kotv_mpv_desktop_shutdown();
    StopTick();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("kotv_mpv respond failed: %s", error->message);
  }
}

static FlMethodErrorResponse* kotv_mpv_listen(FlEventChannel* /*channel*/, FlValue* /*args*/,
                                              gpointer /*user_data*/) {
  g_events_listen = true;
  return nullptr;
}

static FlMethodErrorResponse* kotv_mpv_cancel(FlEventChannel* /*channel*/, FlValue* /*args*/,
                                              gpointer /*user_data*/) {
  g_events_listen = false;
  return nullptr;
}

void kotv_mpv_plugin_register_linux(FlView* view) {
  FlEngine* engine = fl_view_get_engine(view);
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(engine);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_method = fl_method_channel_new(messenger, "kotv_mpv", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_method, kotv_mpv_method_call, view, nullptr);
  g_events = fl_event_channel_new(messenger, "kotv_mpv/events", FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(g_events, kotv_mpv_listen, kotv_mpv_cancel, view, nullptr);
}
