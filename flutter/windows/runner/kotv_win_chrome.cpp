#include "kotv_win_chrome.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>
// PluginRegistrarManager 在 plugin_registrar_windows.h（Flutter 3.19 无独立
// plugin_registrar_manager.h；与 kotv_mpv_plugin 同写法）。

#include <sstream>
#include <type_traits>
#include <variant>

namespace {

// 行模型里的分隔符：'|' 换成 '¦'，换行编码为 \x1F（原生侧还原）。
std::string Sanitize(const std::string& s, bool keep_newline) {
  std::string out;
  out.reserve(s.size());
  for (char ch : s) {
    if (ch == '|') {
      out += "\xC2\xA6";
    } else if (ch == '\n') {
      out += keep_newline ? '\x1F' : ' ';
    } else if (ch != '\r') {
      out += ch;
    }
  }
  return out;
}

std::string JoinUtf8List(const flutter::EncodableList& list) {
  std::ostringstream oss;
  bool first = true;
  for (const auto& v : list) {
    if (!std::holds_alternative<std::string>(v)) continue;
    if (!first) oss << '\n';
    first = false;
    oss << Sanitize(std::get<std::string>(v), false);
  }
  return oss.str();
}

double NumOf(const flutter::EncodableValue& v, double def) {
  if (std::holds_alternative<double>(v)) return std::get<double>(v);
  if (std::holds_alternative<int32_t>(v)) return std::get<int32_t>(v);
  if (std::holds_alternative<int64_t>(v)) return static_cast<double>(std::get<int64_t>(v));
  return def;
}

// id|label|trailing|toggle|on|chevron|slider|min|max|value|icon|kind|selected|sub|divisions
std::string JoinLineItems(const flutter::EncodableList& list) {
  std::ostringstream oss;
  bool first = true;
  for (const auto& v : list) {
    if (!std::holds_alternative<flutter::EncodableMap>(v)) continue;
    const auto& row = std::get<flutter::EncodableMap>(v);
    auto get_s = [&](const char* k) -> std::string {
      const auto it = row.find(flutter::EncodableValue(k));
      if (it == row.end() || !std::holds_alternative<std::string>(it->second)) return {};
      return Sanitize(std::get<std::string>(it->second), true);
    };
    auto get_b = [&](const char* k) -> char {
      const auto it = row.find(flutter::EncodableValue(k));
      return it != row.end() && std::holds_alternative<bool>(it->second) && std::get<bool>(it->second) ? '1'
                                                                                                         : '0';
    };
    auto get_d = [&](const char* k, double def) -> double {
      const auto it = row.find(flutter::EncodableValue(k));
      return it == row.end() ? def : NumOf(it->second, def);
    };
    if (!first) oss << '\n';
    first = false;
    oss << get_s("id") << '|' << get_s("label") << '|' << get_s("trailing") << '|' << get_b("toggle") << '|'
        << get_b("on") << '|' << get_b("chevron") << '|' << get_b("slider") << '|' << get_d("min", 0) << '|'
        << get_d("max", 100) << '|' << get_d("value", 0) << '|' << get_s("icon") << '|' << get_s("kind") << '|'
        << get_b("selected") << '|' << get_s("sub") << '|' << static_cast<int>(get_d("divisions", 0));
  }
  return oss.str();
}

std::string JoinDanmakuItems(const flutter::EncodableList& list) {
  std::ostringstream oss;
  bool first = true;
  for (const auto& v : list) {
    if (!std::holds_alternative<flutter::EncodableMap>(v)) continue;
    const auto& row = std::get<flutter::EncodableMap>(v);
    auto get_s = [&](const char* k) -> std::string {
      const auto it = row.find(flutter::EncodableValue(k));
      if (it == row.end() || !std::holds_alternative<std::string>(it->second)) return {};
      return std::get<std::string>(it->second);
    };
    auto get_d = [&](const char* k) -> double {
      const auto it = row.find(flutter::EncodableValue(k));
      if (it == row.end()) return 0;
      if (std::holds_alternative<double>(it->second)) return std::get<double>(it->second);
      if (std::holds_alternative<int32_t>(it->second)) return std::get<int32_t>(it->second);
      if (std::holds_alternative<int64_t>(it->second))
        return static_cast<double>(std::get<int64_t>(it->second));
      return 0;
    };
    double t = get_d("t");
    if (t == 0) t = get_d("time");
    std::string c = get_s("c");
    if (c.empty()) c = get_s("content");
    int mode = 1;
    {
      const auto it = row.find(flutter::EncodableValue("m"));
      if (it != row.end()) {
        if (std::holds_alternative<int32_t>(it->second)) mode = std::get<int32_t>(it->second);
        else if (std::holds_alternative<int64_t>(it->second))
          mode = static_cast<int>(std::get<int64_t>(it->second));
        else if (std::holds_alternative<double>(it->second))
          mode = static_cast<int>(std::get<double>(it->second));
      } else {
        const auto it2 = row.find(flutter::EncodableValue("mode"));
        if (it2 != row.end() && std::holds_alternative<int32_t>(it2->second))
          mode = std::get<int32_t>(it2->second);
      }
    }
    int color = 0xFFFFFF;
    int size = 25;
    {
      const auto it = row.find(flutter::EncodableValue("color"));
      if (it != row.end()) {
        if (std::holds_alternative<int32_t>(it->second)) color = std::get<int32_t>(it->second);
        else if (std::holds_alternative<int64_t>(it->second))
          color = static_cast<int>(std::get<int64_t>(it->second));
      }
      const auto its = row.find(flutter::EncodableValue("size"));
      if (its != row.end()) {
        if (std::holds_alternative<int32_t>(its->second)) size = std::get<int32_t>(its->second);
        else if (std::holds_alternative<double>(its->second))
          size = static_cast<int>(std::get<double>(its->second));
      }
    }
    if (c.empty()) continue;
    if (!first) oss << '\n';
    first = false;
    oss << t << '|' << Sanitize(c, false) << '|' << mode << '|' << color << '|' << size;
  }
  return oss.str();
}

void FlattenRect(Win7ChromeShell::ChromeMap& out, const flutter::EncodableMap& src,
                 const char* left_k, const char* top_k, const char* w_k, const char* h_k) {
  auto get_d = [&](const char* k) -> double {
    const auto it = src.find(flutter::EncodableValue(k));
    if (it == src.end()) return 0;
    if (std::holds_alternative<double>(it->second)) return std::get<double>(it->second);
    if (std::holds_alternative<int32_t>(it->second)) return std::get<int32_t>(it->second);
    if (std::holds_alternative<int64_t>(it->second))
      return static_cast<double>(std::get<int64_t>(it->second));
    return 0;
  };
  out[left_k] = get_d("left");
  out[top_k] = get_d("top");
  out[w_k] = get_d("width");
  out[h_k] = get_d("height");
}

}  // namespace

KotvWinChrome::KotvWinChrome(flutter::PluginRegistrarWindows* registrar) : registrar_(registrar) {
  shell_.SetEventSink([this](Win7ChromeShell::ChromeMap map) {
    if (event_fn_) event_fn_(FromChromeMap(map));
  });
}

KotvWinChrome::~KotvWinChrome() = default;

void KotvWinChrome::SetEventSink(EventFn fn) { event_fn_ = std::move(fn); }

HWND KotvWinChrome::FlutterHwnd() const {
  return registrar_ ? registrar_->GetView()->GetNativeWindow() : nullptr;
}

Win7ChromeShell::ChromeMap KotvWinChrome::ToChromeMap(const EncodableMap& src) const {
  Win7ChromeShell::ChromeMap out;
  for (const auto& kv : src) {
    if (!std::holds_alternative<std::string>(kv.first)) continue;
    const std::string key = std::get<std::string>(kv.first);
    const auto& v = kv.second;
    if (std::holds_alternative<std::monostate>(v)) continue;
    if (std::holds_alternative<bool>(v)) {
      out[key] = std::get<bool>(v);
    } else if (std::holds_alternative<int32_t>(v)) {
      out[key] = static_cast<int64_t>(std::get<int32_t>(v));
    } else if (std::holds_alternative<int64_t>(v)) {
      out[key] = std::get<int64_t>(v);
    } else if (std::holds_alternative<double>(v)) {
      out[key] = std::get<double>(v);
    } else if (std::holds_alternative<std::string>(v)) {
      out[key] = std::get<std::string>(v);
    } else if (std::holds_alternative<flutter::EncodableList>(v)) {
      const auto& list = std::get<flutter::EncodableList>(v);
      bool maps = false;
      bool danmaku = false;
      for (const auto& e : list) {
        if (!std::holds_alternative<flutter::EncodableMap>(e)) continue;
        maps = true;
        const auto& row = std::get<flutter::EncodableMap>(e);
        danmaku = key == "items" && (row.count(flutter::EncodableValue("c")) ||
                                     row.count(flutter::EncodableValue("content")) ||
                                     row.count(flutter::EncodableValue("t")));
        break;
      }
      if (danmaku) out[key] = JoinDanmakuItems(list);
      else if (maps) out[key] = JoinLineItems(list);
      else out[key] = JoinUtf8List(list);
    } else if (std::holds_alternative<flutter::EncodableMap>(v)) {
      const auto& nested = std::get<flutter::EncodableMap>(v);
      if (key == "anchorScreen") {
        FlattenRect(out, nested, "anchorLeft", "anchorTop", "anchorWidth", "anchorHeight");
      } else if (key == "surfaceScreen") {
        FlattenRect(out, nested, "surfaceLeft", "surfaceTop", "surfaceWidth", "surfaceHeight");
      } else if (key == "danmaku") {
        // 展开到顶层并再 ApplyDanmaku
        auto nested_cm = ToChromeMap(nested);
        for (auto& nkv : nested_cm) out[nkv.first] = std::move(nkv.second);
        out["__danmaku_nested"] = true;
      }
    }
  }
  return out;
}

flutter::EncodableMap KotvWinChrome::FromChromeMap(const Win7ChromeShell::ChromeMap& src) const {
  flutter::EncodableMap out;
  for (const auto& kv : src) {
    flutter::EncodableValue key(kv.first);
    std::visit(
        [&](auto&& val) {
          using T = std::decay_t<decltype(val)>;
          if constexpr (std::is_same_v<T, std::monostate>) {
          } else if constexpr (std::is_same_v<T, bool>) {
            out[key] = val;
          } else if constexpr (std::is_same_v<T, int64_t>) {
            out[key] = val;
          } else if constexpr (std::is_same_v<T, double>) {
            out[key] = val;
          } else if constexpr (std::is_same_v<T, std::string>) {
            out[key] = val;
          }
        },
        kv.second);
  }
  return out;
}

void KotvWinChrome::HandleMethod(const std::string& method, const EncodableMap* args,
                                 std::function<void(EncodableValue)> success,
                                 std::function<void(const std::string&, const std::string&)> error) {
  (void)error;
  HWND hwnd = FlutterHwnd();
  if (hwnd) shell_.Attach(hwnd);

  if (method == "setEnabled") {
    bool en = false;
    if (args) {
      const auto it = args->find(EncodableValue("enabled"));
      if (it != args->end() && std::holds_alternative<bool>(it->second)) en = std::get<bool>(it->second);
    }
    shell_.SetEnabled(en);
    success(EncodableValue(true));
    return;
  }
  if (method == "setDanmaku") {
    if (args) shell_.ApplyDanmaku(ToChromeMap(*args));
    success(EncodableValue(true));
    return;
  }
  if (method == "update") {
    bool need_layout = false;
    if (args) {
      auto cm = ToChromeMap(*args);
      const bool nested_dm = cm.count("__danmaku_nested") != 0;
      cm.erase("__danmaku_nested");
      need_layout = shell_.ApplyUpdate(cm);
      if (nested_dm) shell_.ApplyDanmaku(cm);
    }
    if (shell_.enabled()) {
      if (need_layout) {
        shell_.Layout();
      } else {
        shell_.InvalidateChrome();
      }
    }
    success(EncodableValue(true));
    return;
  }
  if (method == "layout") {
    if (shell_.enabled()) shell_.Layout();
    success(EncodableValue(true));
    return;
  }
  if (method == "showSheet") {
    if (args) shell_.ApplySheet(ToChromeMap(*args));
    success(EncodableValue(true));
    return;
  }
  if (method == "hideSheet") {
    shell_.HideSheet();
    success(EncodableValue(true));
    return;
  }
  success(EncodableValue(false));
}

class KotvWinChromePlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
    auto plugin = std::make_unique<KotvWinChromePlugin>(registrar);
    registrar->AddPlugin(std::move(plugin));
  }

  explicit KotvWinChromePlugin(flutter::PluginRegistrarWindows* registrar) : chrome_(registrar) {
    channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        registrar->messenger(), "kotv_win_chrome", &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          auto shared =
              std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(std::move(result));
          chrome_.HandleMethod(
              call.method_name(), args,
              [shared](flutter::EncodableValue v) { shared->Success(std::move(v)); },
              [shared](const std::string& code, const std::string& msg) { shared->Error(code, msg); });
        });
    chrome_.SetEventSink([this](flutter::EncodableMap map) {
      channel_->InvokeMethod(
          "event", std::make_unique<flutter::EncodableValue>(flutter::EncodableValue(std::move(map))));
    });
  }

 private:
  KotvWinChrome chrome_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

void KotvWinChromeRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  KotvWinChromePlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
