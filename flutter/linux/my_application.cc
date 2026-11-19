#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include <gdk-pixbuf/gdk-pixbuf.h>
#include <gio/gdesktopappinfo.h>
#include <gio/gio.h>
#include <gtk/gtk.h>
#include <stdio.h>
#include <string.h>

#include "flutter/generated_plugin_registrant.h"
#include "runner/mpv/kotv_mpv_plugin.h"

static gboolean kotv_is_browser_app_id(const gchar* id) {
  if (id == nullptr || id[0] == '\0') return TRUE;
  static const char* kBrowsers[] = {
      "firefox", "chrome", "chromium", "brave", "opera", "vivaldi",
      "microsoft-edge", "epiphany", "org.mozilla.firefox",
      "google-chrome", "chromium-browser", "org.gnome.Epiphany",
  };
  for (size_t i = 0; i < G_N_ELEMENTS(kBrowsers); i++) {
    if (g_str_has_prefix(id, kBrowsers[i]) || strstr(id, kBrowsers[i]) != nullptr) {
      return TRUE;
    }
  }
  return FALSE;
}

// 64px PNG；失败则不加 icon 字段，Dart 侧用首字占位。
static FlValue* kotv_app_icon_png(GAppInfo* app) {
  GIcon* icon = g_app_info_get_icon(app);
  if (icon == nullptr) return nullptr;
  GtkIconTheme* theme = gtk_icon_theme_get_default();
  GtkIconInfo* info =
      gtk_icon_theme_lookup_by_gicon(theme, icon, 64, GTK_ICON_LOOKUP_FORCE_SIZE);
  if (info == nullptr) return nullptr;
  GError* err = nullptr;
  GdkPixbuf* pix = gtk_icon_info_load_icon(info, &err);
  g_object_unref(info);
  if (pix == nullptr) {
    if (err != nullptr) g_error_free(err);
    return nullptr;
  }
  gchar* buf = nullptr;
  gsize len = 0;
  const gboolean ok =
      gdk_pixbuf_save_to_buffer(pix, &buf, &len, "png", &err, nullptr);
  g_object_unref(pix);
  if (!ok || buf == nullptr || len == 0) {
    if (err != nullptr) g_error_free(err);
    g_free(buf);
    return nullptr;
  }
  FlValue* bytes = fl_value_new_uint8_list(reinterpret_cast<const uint8_t*>(buf),
                                           static_cast<size_t>(len));
  g_free(buf);
  return bytes;
}

static const char* const kKotvVideoMimeTypes[] = {
    "video/mp4",
    "video/x-matroska",
    "video/webm",
    "video/mpeg",
    "application/vnd.apple.mpegurl",
    "audio/x-mpegurl",
    "audio/mpegurl",
};

// visit 返回 FALSE 时停止；with_icons 为假时不做 PNG（has 探测用）。
static gboolean kotv_for_each_external_video_app(
    gboolean with_icons,
    gboolean (*visit)(GAppInfo* app, const gchar* id, const gchar* name,
                      FlValue* icon_or_null, gpointer user_data),
    gpointer user_data) {
  GHashTable* seen = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, nullptr);
  gboolean keep = TRUE;
  for (size_t t = 0; keep && t < G_N_ELEMENTS(kKotvVideoMimeTypes); t++) {
    GList* apps = g_app_info_get_all_for_type(kKotvVideoMimeTypes[t]);
    for (GList* it = apps; keep && it != nullptr; it = it->next) {
      GAppInfo* app = G_APP_INFO(it->data);
      const gchar* id = g_app_info_get_id(app);
      if (id == nullptr || kotv_is_browser_app_id(id)) continue;
      if (g_hash_table_contains(seen, id)) continue;
      g_hash_table_add(seen, g_strdup(id));
      const gchar* name = g_app_info_get_display_name(app);
      FlValue* icon = with_icons ? kotv_app_icon_png(app) : nullptr;
      keep = visit(app, id, name != nullptr ? name : id, icon, user_data);
      if (!keep && icon != nullptr) {
        fl_value_unref(icon);
      }
    }
    g_list_free_full(apps, g_object_unref);
  }
  g_hash_table_destroy(seen);
  return keep;
}

static gboolean kotv_has_visit(GAppInfo* /*app*/, const gchar* /*id*/,
                               const gchar* /*name*/, FlValue* /*icon*/,
                               gpointer user_data) {
  gboolean* found = static_cast<gboolean*>(user_data);
  *found = TRUE;
  return FALSE;
}

static gboolean kotv_has_external_video_app() {
  gboolean found = FALSE;
  kotv_for_each_external_video_app(FALSE, kotv_has_visit, &found);
  return found;
}

static gboolean kotv_list_visit(GAppInfo* /*app*/, const gchar* id,
                                const gchar* name, FlValue* icon,
                                gpointer user_data) {
  GPtrArray* rows = static_cast<GPtrArray*>(user_data);
  FlValue* row = fl_value_new_map();
  fl_value_set_string_take(row, "id", fl_value_new_string(id));
  fl_value_set_string_take(row, "name", fl_value_new_string(name));
  if (icon != nullptr) {
    fl_value_set_string_take(row, "icon", icon);
  }
  g_ptr_array_add(rows, row);
  return TRUE;
}

static gint kotv_external_app_name_cmp(gconstpointer a, gconstpointer b) {
  FlValue* ma = *static_cast<FlValue* const*>(a);
  FlValue* mb = *static_cast<FlValue* const*>(b);
  FlValue* na = fl_value_lookup_string(ma, "name");
  FlValue* nb = fl_value_lookup_string(mb, "name");
  const gchar* sa = na != nullptr ? fl_value_get_string(na) : "";
  const gchar* sb = nb != nullptr ? fl_value_get_string(nb) : "";
  return g_utf8_collate(sa, sb);
}

static FlValue* kotv_list_external_video_apps() {
  GPtrArray* rows = g_ptr_array_new();
  kotv_for_each_external_video_app(TRUE, kotv_list_visit, rows);
  g_ptr_array_sort(rows, kotv_external_app_name_cmp);
  FlValue* list = fl_value_new_list();
  for (guint i = 0; i < rows->len; i++) {
    fl_value_append_take(list, static_cast<FlValue*>(g_ptr_array_index(rows, i)));
  }
  // 行已交给 list；只拆数组壳。
  g_ptr_array_free(rows, FALSE);
  return list;
}

// 把当前播放地址 URI 原样交给选定应用。
static gboolean kotv_open_external_video_app(const gchar* id, const gchar* url) {
  if (id == nullptr || url == nullptr || id[0] == '\0' || url[0] == '\0') {
    return FALSE;
  }
  GDesktopAppInfo* desktop = g_desktop_app_info_new(id);
  if (desktop == nullptr) return FALSE;
  GAppInfo* app = G_APP_INFO(desktop);
  GList* uris = nullptr;
  uris = g_list_append(uris, g_strdup(url));
  GError* err = nullptr;
  const gboolean ok = g_app_info_launch_uris(app, uris, nullptr, &err);
  if (err != nullptr) {
    g_error_free(err);
  }
  g_list_free_full(uris, g_free);
  g_object_unref(desktop);
  return ok;
}

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* host_channel;
};

static gint64 kotv_interface_rx_bytes() {
  FILE* f = fopen("/proc/net/dev", "r");
  if (f == nullptr) {
    return -1;
  }
  char line[512];
  // skip headers
  if (fgets(line, sizeof(line), f) == nullptr ||
      fgets(line, sizeof(line), f) == nullptr) {
    fclose(f);
    return -1;
  }
  guint64 total = 0;
  while (fgets(line, sizeof(line), f) != nullptr) {
    char* colon = strchr(line, ':');
    if (colon == nullptr) {
      continue;
    }
    *colon = '\0';
    char* name = line;
    while (*name == ' ') {
      ++name;
    }
    if (strcmp(name, "lo") == 0) {
      continue;
    }
    unsigned long long rx = 0;
    if (sscanf(colon + 1, "%llu", &rx) == 1) {
      total += rx;
    }
  }
  fclose(f);
  return static_cast<gint64>(total);
}

static gint64 kotv_memory_total_bytes() {
  FILE* f = fopen("/proc/meminfo", "r");
  if (f == nullptr) {
    return 0;
  }
  char key[64];
  unsigned long long val = 0;
  char unit[16];
  while (fscanf(f, "%63s %llu %15s", key, &val, unit) == 3) {
    if (strcmp(key, "MemTotal:") == 0) {
      fclose(f);
      return static_cast<gint64>(val * 1024ULL);
    }
  }
  fclose(f);
  return 0;
}

static gint64 kotv_memory_avail_bytes() {
  FILE* f = fopen("/proc/meminfo", "r");
  if (f == nullptr) {
    return 0;
  }
  char key[64];
  unsigned long long val = 0;
  char unit[16];
  gint64 avail = 0;
  gint64 total = 0;
  gint64 free = 0;
  while (fscanf(f, "%63s %llu %15s", key, &val, unit) == 3) {
    if (strcmp(key, "MemTotal:") == 0) {
      total = static_cast<gint64>(val * 1024ULL);
    } else if (strcmp(key, "MemAvailable:") == 0) {
      avail = static_cast<gint64>(val * 1024ULL);
    } else if (strcmp(key, "MemFree:") == 0) {
      free = static_cast<gint64>(val * 1024ULL);
    }
  }
  fclose(f);
  if (avail > 0) {
    return avail;
  }
  if (free > 0) {
    return free;
  }
  return total;
}

static void kotv_host_method_call(FlMethodChannel* /*channel*/,
                                  FlMethodCall* method_call,
                                  gpointer /*user_data*/) {
  const gchar* method = fl_method_call_get_name(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (strcmp(method, "getInterfaceRxBytes") == 0) {
    g_autoptr(FlValue) result =
        fl_value_new_int(kotv_interface_rx_bytes());
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else if (strcmp(method, "getMemoryInfo") == 0) {
    g_autoptr(FlValue) map = fl_value_new_map();
    fl_value_set_string_take(map, "totalBytes",
                             fl_value_new_int(kotv_memory_total_bytes()));
    fl_value_set_string_take(map, "availBytes",
                             fl_value_new_int(kotv_memory_avail_bytes()));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(map));
  } else if (strcmp(method, "hasExternalVideoApp") == 0) {
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(
        fl_value_new_bool(kotv_has_external_video_app())));
  } else if (strcmp(method, "listExternalVideoApps") == 0) {
    response = FL_METHOD_RESPONSE(
        fl_method_success_response_new(kotv_list_external_video_apps()));
  } else if (strcmp(method, "openExternalVideoApp") == 0) {
    FlValue* args = fl_method_call_get_args(method_call);
    const gchar* id = nullptr;
    const gchar* url = nullptr;
    if (fl_value_get_type(args) == FL_VALUE_TYPE_MAP) {
      FlValue* id_v = fl_value_lookup_string(args, "id");
      FlValue* url_v = fl_value_lookup_string(args, "url");
      if (id_v != nullptr && fl_value_get_type(id_v) == FL_VALUE_TYPE_STRING) {
        id = fl_value_get_string(id_v);
      }
      if (url_v != nullptr && fl_value_get_type(url_v) == FL_VALUE_TYPE_STRING) {
        url = fl_value_get_string(url_v);
      }
    }
    const gboolean ok = kotv_open_external_video_app(id, url);
    response = FL_METHOD_RESPONSE(
        fl_method_success_response_new(fl_value_new_bool(ok)));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to send method response: %s", error->message);
  }
}

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  GList* existing = gtk_application_get_windows(GTK_APPLICATION(application));
  if (existing != nullptr) {
    gtk_window_present(GTK_WINDOW(existing->data));
    return;
  }

  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "kotv");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "kotv");
  }

  gtk_window_set_default_size(window, 1280, 720);
  gtk_widget_show(GTK_WIDGET(window));

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  kotv_mpv_plugin_register_with_registrar(
      fl_plugin_registry_get_registrar_for_plugin(FL_PLUGIN_REGISTRY(view),
                                                  "KotvMpvPlugin"));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->host_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)), "kotv_host",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->host_channel, kotv_host_method_call, self, nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application, gchar*** arguments, int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
     g_warning("Failed to register: %s", error->message);
     *exit_status = 1;
     return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  //MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  //MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->host_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line = my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {
  self->host_channel = nullptr;
}

MyApplication* my_application_new() {
  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID,
                                     "flags", static_cast<GApplicationFlags>(0),
                                     nullptr));
}
