#include "include/kotv_vlc/kotv_vlc_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include <atomic>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

extern "C" {
#include "vlc_shim.h"
}

#define KOTV_VLC_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), kotv_vlc_plugin_get_type(), KotvVlcPlugin))

struct _KotvVlcPlugin {
  GObject parent_instance;
  FlMethodChannel* channel;
  FlTextureRegistrar* textures;
  FlTexture* texture;
  int64_t texture_id;
  gboolean ready;

  std::mutex* frame_mu;
  std::vector<uint8_t>* frame_rgba;
  int frame_w;
  int frame_h;

  std::atomic<bool>* pump_running;
  std::thread* pump;
};

G_DEFINE_TYPE(KotvVlcPlugin, kotv_vlc_plugin, g_object_get_type())

// PixelBuffer texture subclass
typedef struct {
  FlPixelBufferTexture parent_instance;
  KotvVlcPlugin* plugin;
} KotvTexture;

typedef struct {
  FlPixelBufferTextureClass parent_class;
} KotvTextureClass;

G_DEFINE_TYPE(KotvTexture, kotv_texture, fl_pixel_buffer_texture_get_type())

#define KOTV_TEXTURE(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), kotv_texture_get_type(), KotvTexture))

static gboolean kotv_texture_copy_pixels(FlPixelBufferTexture* texture,
                                         const uint8_t** buffer,
                                         uint32_t* width,
                                         uint32_t* height,
                                         GError** error) {
  KotvTexture* self = KOTV_TEXTURE(texture);
  KotvVlcPlugin* p = self->plugin;
  if (!p || !p->frame_mu || !p->frame_rgba) {
    return FALSE;
  }
  std::lock_guard<std::mutex> lock(*p->frame_mu);
  if (p->frame_w < 2 || p->frame_h < 2 || p->frame_rgba->empty()) {
    return FALSE;
  }
  *buffer = p->frame_rgba->data();
  *width = (uint32_t)p->frame_w;
  *height = (uint32_t)p->frame_h;
  return TRUE;
}

static void kotv_texture_class_init(KotvTextureClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels = kotv_texture_copy_pixels;
}

static void kotv_texture_init(KotvTexture* self) { self->plugin = nullptr; }

static void stop_pump(KotvVlcPlugin* self) {
  if (!self->pump_running) return;
  if (!self->pump_running->exchange(false)) return;
  if (self->pump && self->pump->joinable()) {
    self->pump->join();
  }
}

static void start_pump(KotvVlcPlugin* self) {
  if (!self->pump_running) return;
  if (self->pump_running->exchange(true)) return;
  if (self->pump) {
    delete self->pump;
    self->pump = nullptr;
  }
  self->pump = new std::thread([self]() {
    std::vector<uint8_t> tmp;
    while (self->pump_running->load()) {
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
          std::lock_guard<std::mutex> lock(*self->frame_mu);
          self->frame_rgba->assign(tmp.begin(),
                                   tmp.begin() + (std::ptrdiff_t)bytes);
          for (size_t i = 3; i < bytes; i += 4) {
            (*self->frame_rgba)[i] = 255;
          }
          self->frame_w = w;
          self->frame_h = h;
        }
        if (self->textures && self->texture) {
          fl_texture_registrar_mark_texture_frame_available(self->textures,
                                                            self->texture);
        }
      }
      g_usleep(16000);
    }
  });
}

static void dispose_player(KotvVlcPlugin* self) {
  stop_pump(self);
  kotv_vlc_stop();
  self->ready = FALSE;
  if (self->textures && self->texture) {
    fl_texture_registrar_unregister_texture(self->textures, self->texture);
    g_clear_object(&self->texture);
    self->texture_id = -1;
  }
}

static FlMethodResponse* respond_ok() {
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static FlMethodResponse* respond_map(FlValue* map) {
  return FL_METHOD_RESPONSE(fl_method_success_response_new(map));
}

static void method_call_cb(FlMethodChannel*, FlMethodCall* method_call,
                           gpointer user_data) {
  KotvVlcPlugin* self = KOTV_VLC_PLUGIN(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (strcmp(method, "create") == 0) {
    dispose_player(self);
    KotvTexture* tex =
        KOTV_TEXTURE(g_object_new(kotv_texture_get_type(), nullptr));
    tex->plugin = self;
    self->texture = FL_TEXTURE(tex);
    // Flutter Linux: register returns gboolean; id via fl_texture_get_id.
    if (!fl_texture_registrar_register_texture(self->textures, self->texture)) {
      response = FL_METHOD_RESPONSE(
          fl_method_error_response_new("create", "register texture failed",
                                       nullptr));
    } else {
      self->texture_id = fl_texture_get_id(self->texture);
      g_autoptr(FlValue) map = fl_value_new_map();
      fl_value_set_string_take(map, "textureId",
                               fl_value_new_int(self->texture_id));
      response = respond_map(map);
    }
  } else if (strcmp(method, "load") == 0) {
    const gchar* lib = nullptr;
    const gchar* plug = nullptr;
    FlValue* vlib = fl_value_lookup_string(args, "libDir");
    FlValue* vplg = fl_value_lookup_string(args, "pluginDir");
    if (vlib) lib = fl_value_get_string(vlib);
    if (vplg) plug = fl_value_get_string(vplg);
    int rc = kotv_vlc_load(lib ? lib : "", plug ? plug : "");
    if (rc != 0) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "load", g_strdup_printf("libvlc load failed (%d)", rc), nullptr));
    } else {
      self->ready = TRUE;
      response = respond_ok();
    }
  } else if (strcmp(method, "play") == 0) {
    if (!self->ready) {
      response = FL_METHOD_RESPONSE(
          fl_method_error_response_new("play", "libvlc not loaded", nullptr));
    } else {
      FlValue* u = fl_value_lookup_string(args, "url");
      const gchar* url = u ? fl_value_get_string(u) : "";
      int rc = kotv_vlc_play(url ? url : "");
      if (rc != 0) {
        response = FL_METHOD_RESPONSE(fl_method_error_response_new(
            "play", g_strdup_printf("vlc play failed (%d)", rc), nullptr));
      } else {
        start_pump(self);
        response = respond_ok();
      }
    }
  } else if (strcmp(method, "stop") == 0) {
    stop_pump(self);
    kotv_vlc_stop();
    response = respond_ok();
  } else if (strcmp(method, "pause") == 0) {
    kotv_vlc_pause(1);
    response = respond_ok();
  } else if (strcmp(method, "resume") == 0) {
    kotv_vlc_pause(0);
    response = respond_ok();
  } else if (strcmp(method, "toggle") == 0) {
    gboolean playing = kotv_vlc_is_playing() != 0;
    kotv_vlc_pause(playing ? 1 : 0);
    g_autoptr(FlValue) map = fl_value_new_map();
    fl_value_set_string_take(map, "playing", fl_value_new_bool(!playing));
    response = respond_map(map);
  } else if (strcmp(method, "seek") == 0) {
    FlValue* v = fl_value_lookup_string(args, "ms");
    kotv_vlc_set_time(v ? fl_value_get_int(v) : 0);
    response = respond_ok();
  } else if (strcmp(method, "volume") == 0) {
    FlValue* v = fl_value_lookup_string(args, "value");
    kotv_vlc_set_volume(v ? (int)fl_value_get_int(v) : 80);
    response = respond_ok();
  } else if (strcmp(method, "rate") == 0) {
    FlValue* v = fl_value_lookup_string(args, "value");
    double r = 1.0;
    if (v && fl_value_get_type(v) == FL_VALUE_TYPE_FLOAT)
      r = fl_value_get_float(v);
    else if (v)
      r = (double)fl_value_get_int(v);
    kotv_vlc_set_rate((float)r);
    response = respond_ok();
  } else if (strcmp(method, "decode") == 0) {
    FlValue* m = fl_value_lookup_string(args, "mode");
    const gchar* mode = m ? fl_value_get_string(m) : nullptr;
    if (mode && strcmp(mode, "soft") == 0) {
      kotv_vlc_set_decode(1);
    } else if (mode && strcmp(mode, "hard") == 0) {
      kotv_vlc_set_decode(0);
    } else if (mode && strcmp(mode, "auto") == 0) {
      kotv_vlc_set_decode(-1);
    } else {
      FlValue* v = fl_value_lookup_string(args, "soft");
      kotv_vlc_set_decode(v && fl_value_get_bool(v) ? 1 : 0);
    }
    response = respond_ok();
  } else if (strcmp(method, "repeat") == 0) {
    FlValue* v = fl_value_lookup_string(args, "on");
    kotv_vlc_set_repeat(v && fl_value_get_bool(v) ? 1 : 0);
    response = respond_ok();
  } else if (strcmp(method, "tracks") == 0) {
    FlValue* vt = fl_value_lookup_string(args, "type");
    int type = vt ? (int)fl_value_get_int(vt) : 0;
    char buf[8192];
    int n = kotv_vlc_track_list(type, buf, (int)sizeof(buf));
    g_autoptr(FlValue) list = fl_value_new_list();
    if (n > 0) {
      gchar** lines = g_strsplit(buf, "\n", -1);
      for (int i = 0; lines && lines[i]; i++) {
        if (!lines[i][0]) continue;
        gchar** parts = g_strsplit(lines[i], "\t", 2);
        g_autoptr(FlValue) row = fl_value_new_map();
        fl_value_set_string_take(row, "id",
                                 fl_value_new_string(parts[0] ? parts[0] : ""));
        fl_value_set_string_take(
            row, "name",
            fl_value_new_string(parts[1] ? parts[1] : (parts[0] ? parts[0] : "")));
        fl_value_append(list, row);
        g_strfreev(parts);
      }
      g_strfreev(lines);
    }
    g_autoptr(FlValue) map = fl_value_new_map();
    fl_value_set_string(map, "tracks", list);
    fl_value_set_string_take(map, "current",
                             fl_value_new_int(kotv_vlc_get_track(type)));
    fl_value_set_string_take(map, "count", fl_value_new_int(n < 0 ? 0 : n));
    response = respond_map(map);
  } else if (strcmp(method, "setTrack") == 0) {
    FlValue* vt = fl_value_lookup_string(args, "type");
    FlValue* vi = fl_value_lookup_string(args, "id");
    int type = vt ? (int)fl_value_get_int(vt) : 0;
    int tid = vi ? (int)fl_value_get_int(vi) : -1;
    int rc = kotv_vlc_set_track(type, tid);
    if (rc < 0) {
      response = FL_METHOD_RESPONSE(
          fl_method_error_response_new("setTrack", "set track failed", nullptr));
    } else {
      response = respond_ok();
    }
  } else if (strcmp(method, "status") == 0) {
    int w = 0, h = 0;
    {
      std::lock_guard<std::mutex> lock(*self->frame_mu);
      w = self->frame_w;
      h = self->frame_h;
    }
    int vw = 0, vh = 0;
    if (kotv_vlc_video_size(&vw, &vh) == 0 && vw > 0 && vh > 0) {
      w = vw;
      h = vh;
    }
    g_autoptr(FlValue) map = fl_value_new_map();
    fl_value_set_string_take(map, "playing",
                             fl_value_new_bool(kotv_vlc_is_playing() != 0));
    fl_value_set_string_take(map, "positionMs",
                             fl_value_new_int(kotv_vlc_get_time()));
    fl_value_set_string_take(map, "durationMs",
                             fl_value_new_int(kotv_vlc_get_length()));
    fl_value_set_string_take(map, "width", fl_value_new_int(w));
    fl_value_set_string_take(map, "height", fl_value_new_int(h));
    fl_value_set_string_take(map, "rate",
                             fl_value_new_float(kotv_vlc_get_rate()));
    fl_value_set_string_take(map, "textureId",
                             fl_value_new_int(self->texture_id));
    response = respond_map(map);
  } else if (strcmp(method, "dispose") == 0) {
    dispose_player(self);
    response = respond_ok();
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

static void kotv_vlc_plugin_dispose(GObject* object) {
  KotvVlcPlugin* self = KOTV_VLC_PLUGIN(object);
  dispose_player(self);
  g_clear_object(&self->channel);
  if (self->pump) {
    delete self->pump;
    self->pump = nullptr;
  }
  if (self->pump_running) {
    delete self->pump_running;
    self->pump_running = nullptr;
  }
  if (self->frame_mu) {
    delete self->frame_mu;
    self->frame_mu = nullptr;
  }
  if (self->frame_rgba) {
    delete self->frame_rgba;
    self->frame_rgba = nullptr;
  }
  G_OBJECT_CLASS(kotv_vlc_plugin_parent_class)->dispose(object);
}

static void kotv_vlc_plugin_class_init(KotvVlcPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = kotv_vlc_plugin_dispose;
}

static void kotv_vlc_plugin_init(KotvVlcPlugin* self) {
  self->texture_id = -1;
  self->ready = FALSE;
  self->frame_mu = new std::mutex();
  self->frame_rgba = new std::vector<uint8_t>();
  self->frame_w = 0;
  self->frame_h = 0;
  self->pump_running = new std::atomic<bool>(false);
  self->pump = nullptr;
  self->texture = nullptr;
}

void kotv_vlc_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  KotvVlcPlugin* plugin =
      KOTV_VLC_PLUGIN(g_object_new(kotv_vlc_plugin_get_type(), nullptr));
  plugin->textures = fl_plugin_registrar_get_texture_registrar(registrar);

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  plugin->channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), "kotv_vlc",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(plugin->channel, method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);
  g_object_unref(plugin);
}
