#include "kotv_win_chrome.h"
#include "utils.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <unordered_map>
#include <vector>

#include <flutter/plugin_registrar_manager.h>

#include <commctrl.h>
#pragma comment(lib, "comctl32.lib")

// ---------------------------------------------------------------------------
// 极简 JSON（EncodableValue ↔ 文本行）。仅服务 Win7 WPF 桥，勿与 Win8+ 混用。
// ---------------------------------------------------------------------------

namespace {

std::string JsonEscape(const std::string& s) {
  std::string o;
  o.reserve(s.size() + 8);
  for (unsigned char c : s) {
    switch (c) {
      case '"':
        o += "\\\"";
        break;
      case '\\':
        o += "\\\\";
        break;
      case '\n':
        o += "\\n";
        break;
      case '\r':
        o += "\\r";
        break;
      case '\t':
        o += "\\t";
        break;
      default:
        if (c < 0x20) {
          char buf[8];
          snprintf(buf, sizeof(buf), "\\u%04x", c);
          o += buf;
        } else {
          o.push_back(static_cast<char>(c));
        }
    }
  }
  return o;
}

std::string EncodeJson(const flutter::EncodableValue& v);

std::string EncodeJson(const flutter::EncodableMap& m) {
  std::ostringstream oss;
  oss << '{';
  bool first = true;
  for (const auto& kv : m) {
    if (!std::holds_alternative<std::string>(kv.first)) continue;
    if (!first) oss << ',';
    first = false;
    oss << '"' << JsonEscape(std::get<std::string>(kv.first)) << '"' << ':' << EncodeJson(kv.second);
  }
  oss << '}';
  return oss.str();
}

std::string EncodeJson(const flutter::EncodableList& list) {
  std::ostringstream oss;
  oss << '[';
  for (size_t i = 0; i < list.size(); ++i) {
    if (i) oss << ',';
    oss << EncodeJson(list[i]);
  }
  oss << ']';
  return oss.str();
}

std::string EncodeJson(const flutter::EncodableValue& v) {
  if (std::holds_alternative<std::monostate>(v)) return "null";
  if (std::holds_alternative<bool>(v)) return std::get<bool>(v) ? "true" : "false";
  if (std::holds_alternative<int32_t>(v)) return std::to_string(std::get<int32_t>(v));
  if (std::holds_alternative<int64_t>(v)) return std::to_string(std::get<int64_t>(v));
  if (std::holds_alternative<double>(v)) {
    std::ostringstream oss;
    oss.setf(std::ios::fmtflags(0), std::ios::floatfield);
    oss.precision(15);
    oss << std::get<double>(v);
    return oss.str();
  }
  if (std::holds_alternative<std::string>(v))
    return std::string("\"") + JsonEscape(std::get<std::string>(v)) + "\"";
  if (std::holds_alternative<flutter::EncodableList>(v))
    return EncodeJson(std::get<flutter::EncodableList>(v));
  if (std::holds_alternative<flutter::EncodableMap>(v))
    return EncodeJson(std::get<flutter::EncodableMap>(v));
  return "null";
}

// ---- tiny recursive descent ----

struct JsonParser {
  const std::string& s;
  size_t i = 0;
  explicit JsonParser(const std::string& in) : s(in) {}

  void Skip() {
    while (i < s.size() && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n')) ++i;
  }

  bool Match(char c) {
    Skip();
    if (i < s.size() && s[i] == c) {
      ++i;
      return true;
    }
    return false;
  }

  flutter::EncodableValue Parse() {
    Skip();
    if (i >= s.size()) return flutter::EncodableValue();
    char c = s[i];
    if (c == '{') return ParseObject();
    if (c == '[') return ParseArray();
    if (c == '"') return ParseString();
    if (c == 't' || c == 'f') return ParseBool();
    if (c == 'n') {
      i += 4;
      return flutter::EncodableValue();
    }
    return ParseNumber();
  }

  flutter::EncodableValue ParseObject() {
    Match('{');
    flutter::EncodableMap m;
    Skip();
    if (Match('}')) return m;
    while (true) {
      auto key_v = ParseString();
      if (!std::holds_alternative<std::string>(key_v)) break;
      if (!Match(':')) break;
      m[flutter::EncodableValue(std::get<std::string>(key_v))] = Parse();
      Skip();
      if (Match('}')) break;
      if (!Match(',')) break;
    }
    return m;
  }

  flutter::EncodableValue ParseArray() {
    Match('[');
    flutter::EncodableList list;
    Skip();
    if (Match(']')) return list;
    while (true) {
      list.push_back(Parse());
      Skip();
      if (Match(']')) break;
      if (!Match(',')) break;
    }
    return list;
  }

  flutter::EncodableValue ParseString() {
    if (!Match('"')) return std::string();
    std::string out;
    while (i < s.size()) {
      char c = s[i++];
      if (c == '"') break;
      if (c == '\\' && i < s.size()) {
        char e = s[i++];
        switch (e) {
          case '"':
          case '\\':
          case '/':
            out.push_back(e);
            break;
          case 'n':
            out.push_back('\n');
            break;
          case 'r':
            out.push_back('\r');
            break;
          case 't':
            out.push_back('\t');
            break;
          case 'u':
            if (i + 4 <= s.size()) {
              unsigned code = 0;
              for (int k = 0; k < 4; ++k) {
                char h = s[i++];
                code <<= 4;
                if (h >= '0' && h <= '9')
                  code |= h - '0';
                else if (h >= 'a' && h <= 'f')
                  code |= h - 'a' + 10;
                else if (h >= 'A' && h <= 'F')
                  code |= h - 'A' + 10;
              }
              if (code < 0x80)
                out.push_back(static_cast<char>(code));
              else if (code < 0x800) {
                out.push_back(static_cast<char>(0xC0 | (code >> 6)));
                out.push_back(static_cast<char>(0x80 | (code & 0x3F)));
              } else {
                out.push_back(static_cast<char>(0xE0 | (code >> 12)));
                out.push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3F)));
                out.push_back(static_cast<char>(0x80 | (code & 0x3F)));
              }
            }
            break;
          default:
            out.push_back(e);
        }
      } else {
        out.push_back(c);
      }
    }
    return out;
  }

  flutter::EncodableValue ParseBool() {
    if (s.compare(i, 4, "true") == 0) {
      i += 4;
      return true;
    }
    if (s.compare(i, 5, "false") == 0) {
      i += 5;
      return false;
    }
    return false;
  }

  flutter::EncodableValue ParseNumber() {
    size_t start = i;
    if (i < s.size() && (s[i] == '-' || s[i] == '+')) ++i;
    while (i < s.size() && s[i] >= '0' && s[i] <= '9') ++i;
    bool is_float = false;
    if (i < s.size() && s[i] == '.') {
      is_float = true;
      ++i;
      while (i < s.size() && s[i] >= '0' && s[i] <= '9') ++i;
    }
    if (i < s.size() && (s[i] == 'e' || s[i] == 'E')) {
      is_float = true;
      ++i;
      if (i < s.size() && (s[i] == '-' || s[i] == '+')) ++i;
      while (i < s.size() && s[i] >= '0' && s[i] <= '9') ++i;
    }
    const std::string num = s.substr(start, i - start);
    if (is_float) return std::strtod(num.c_str(), nullptr);
    long long v = std::strtoll(num.c_str(), nullptr, 10);
    if (v >= INT32_MIN && v <= INT32_MAX) return static_cast<int32_t>(v);
    return static_cast<int64_t>(v);
  }
};

flutter::EncodableValue ParseJson(const std::string& s) {
  JsonParser p(s);
  return p.Parse();
}

std::wstring ExeDir() {
  wchar_t path[MAX_PATH] = {};
  GetModuleFileNameW(nullptr, path, MAX_PATH);
  std::wstring p(path);
  auto slash = p.find_last_of(L"\\/");
  if (slash == std::wstring::npos) return L".";
  return p.substr(0, slash);
}

DWORD WINAPI ReaderThreadProc(LPVOID param) {
  auto* self = reinterpret_cast<KotvWinChrome*>(param);
  self->ReaderLoop();
  return 0;
}

}  // namespace

// ---------------------------------------------------------------------------

KotvWinChrome::KotvWinChrome(flutter::PluginRegistrarWindows* registrar) : registrar_(registrar) {
  InitializeCriticalSection(&io_lock_);
  ready_event_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
}

KotvWinChrome::~KotvWinChrome() {
  StopProcess();
  if (subclassed_) {
    HWND hwnd = FlutterHwnd();
    if (hwnd) RemoveWindowSubclass(hwnd, HostWndSubclass, subclass_id_);
    subclassed_ = false;
  }
  if (ready_event_) {
    CloseHandle(ready_event_);
    ready_event_ = nullptr;
  }
  DeleteCriticalSection(&io_lock_);
}

void KotvWinChrome::SetEventSink(EventFn fn) { event_fn_ = std::move(fn); }

HWND KotvWinChrome::FlutterHwnd() const {
  return registrar_ ? registrar_->GetView()->GetNativeWindow() : nullptr;
}

void KotvWinChrome::EnsureSubclass() {
  if (subclassed_) return;
  HWND hwnd = FlutterHwnd();
  if (!hwnd) return;
  if (SetWindowSubclass(hwnd, HostWndSubclass, subclass_id_, reinterpret_cast<DWORD_PTR>(this))) {
    subclassed_ = true;
  }
}

LRESULT CALLBACK KotvWinChrome::HostWndSubclass(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam,
                                                UINT_PTR id, DWORD_PTR data) {
  auto* self = reinterpret_cast<KotvWinChrome*>(data);
  if (msg == kWmChromeEvent && self) {
    self->FlushEventsOnPlatformThread();
    return 0;
  }
  return DefSubclassProc(hwnd, msg, wParam, lParam);
}

void KotvWinChrome::FlushEventsOnPlatformThread() {
  std::vector<EncodableMap> batch;
  EnterCriticalSection(&io_lock_);
  batch.swap(event_queue_);
  LeaveCriticalSection(&io_lock_);
  for (auto& m : batch) {
    if (event_fn_) event_fn_(std::move(m));
  }
}

void KotvWinChrome::Emit(EncodableMap map) {
  EnsureSubclass();
  EnterCriticalSection(&io_lock_);
  event_queue_.push_back(std::move(map));
  LeaveCriticalSection(&io_lock_);
  HWND hwnd = FlutterHwnd();
  if (hwnd) PostMessageW(hwnd, kWmChromeEvent, 0, 0);
}

int64_t KotvWinChrome::NextId() { return InterlockedIncrement(&next_id_); }

bool KotvWinChrome::EnsureProcess() {
  if (proc_ && WaitForSingleObject(proc_, 0) == WAIT_TIMEOUT) return true;

  StopProcess();

  SECURITY_ATTRIBUTES sa{};
  sa.nLength = sizeof(sa);
  sa.bInheritHandle = TRUE;

  HANDLE stdin_rd = nullptr, stdout_wr = nullptr;
  if (!CreatePipe(&stdin_rd, &stdin_wr_, &sa, 0)) return false;
  if (!SetHandleInformation(stdin_wr_, HANDLE_FLAG_INHERIT, 0)) return false;
  if (!CreatePipe(&stdout_rd_, &stdout_wr, &sa, 0)) return false;
  if (!SetHandleInformation(stdout_rd_, HANDLE_FLAG_INHERIT, 0)) return false;

  const std::wstring exe = ExeDir() + L"\\kotv_win7_chrome.exe";
  STARTUPINFOW si{};
  si.cb = sizeof(si);
  si.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
  si.wShowWindow = SW_HIDE;
  si.hStdInput = stdin_rd;
  si.hStdOutput = stdout_wr;
  si.hStdError = GetStdHandle(STD_ERROR_HANDLE);

  PROCESS_INFORMATION pi{};
  std::wstring cmd = L"\"" + exe + L"\"";
  std::vector<wchar_t> buf(cmd.begin(), cmd.end());
  buf.push_back(0);

  BOOL ok = CreateProcessW(nullptr, buf.data(), nullptr, nullptr, TRUE,
                           CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT, nullptr, ExeDir().c_str(),
                           &si, &pi);
  CloseHandle(stdin_rd);
  CloseHandle(stdout_wr);
  if (!ok) {
    CloseHandle(stdin_wr_);
    stdin_wr_ = nullptr;
    CloseHandle(stdout_rd_);
    stdout_rd_ = nullptr;
    return false;
  }
  CloseHandle(pi.hThread);
  proc_ = pi.hProcess;
  if (ready_event_) ResetEvent(ready_event_);
  InterlockedExchange(&alive_, 1);
  reader_thread_ = CreateThread(nullptr, 0, ReaderThreadProc, this, 0, nullptr);
  // 等 WPF ready 事件（最多 5s）
  HANDLE waits[2] = {ready_event_, proc_};
  const DWORD wr = WaitForMultipleObjects(2, waits, FALSE, 5000);
  if (wr != WAIT_OBJECT_0) {
    StopProcess();
    return false;
  }
  return true;
}

void KotvWinChrome::StopProcess() {
  InterlockedExchange(&alive_, 0);
  if (stdin_wr_) {
    CloseHandle(stdin_wr_);
    stdin_wr_ = nullptr;
  }
  if (proc_) {
    TerminateProcess(proc_, 0);
    WaitForSingleObject(proc_, 1000);
    CloseHandle(proc_);
    proc_ = nullptr;
  }
  if (reader_thread_) {
    WaitForSingleObject(reader_thread_, 1000);
    CloseHandle(reader_thread_);
    reader_thread_ = nullptr;
  }
  if (stdout_rd_) {
    CloseHandle(stdout_rd_);
    stdout_rd_ = nullptr;
  }
  EnterCriticalSection(&io_lock_);
  for (auto& kv : pending_) {
    if (kv.second && kv.second->event) SetEvent(kv.second->event);
  }
  pending_.clear();
  LeaveCriticalSection(&io_lock_);
}

void KotvWinChrome::ReaderLoop() {
  std::string buf;
  char tmp[1024];
  while (InterlockedCompareExchange(&alive_, 1, 1) == 1 && stdout_rd_) {
    DWORD got = 0;
    if (!ReadFile(stdout_rd_, tmp, sizeof(tmp), &got, nullptr) || got == 0) break;
    buf.append(tmp, tmp + got);
    size_t pos;
    while ((pos = buf.find('\n')) != std::string::npos) {
      std::string line = buf.substr(0, pos);
      buf.erase(0, pos + 1);
      if (!line.empty() && line.back() == '\r') line.pop_back();
      if (!line.empty()) HandleRemoteLine(line);
    }
  }
}

void KotvWinChrome::HandleRemoteLine(const std::string& line) {
  auto root_v = ParseJson(line);
  if (!std::holds_alternative<flutter::EncodableMap>(root_v)) return;
  const auto& root = std::get<flutter::EncodableMap>(root_v);

  auto it_event = root.find(flutter::EncodableValue("event"));
  if (it_event != root.end() && std::holds_alternative<std::string>(it_event->second)) {
    const std::string ev = std::get<std::string>(it_event->second);
    if (ev == "ready") {
      if (ready_event_) SetEvent(ready_event_);
      return;
    }
    if (ev == "action") {
      auto pit = root.find(flutter::EncodableValue("payload"));
      if (pit != root.end() && std::holds_alternative<flutter::EncodableMap>(pit->second)) {
        const auto& payload = std::get<flutter::EncodableMap>(pit->second);
        auto dit = payload.find(flutter::EncodableValue("data"));
        if (dit != payload.end() && std::holds_alternative<flutter::EncodableMap>(dit->second)) {
          Emit(std::get<flutter::EncodableMap>(dit->second));
        } else {
          Emit(payload);
        }
      }
      return;
    }
  }

  auto id_it = root.find(flutter::EncodableValue("id"));
  if (id_it == root.end()) return;
  int64_t id = 0;
  if (std::holds_alternative<int32_t>(id_it->second))
    id = std::get<int32_t>(id_it->second);
  else if (std::holds_alternative<int64_t>(id_it->second))
    id = std::get<int64_t>(id_it->second);
  else if (std::holds_alternative<double>(id_it->second))
    id = static_cast<int64_t>(std::get<double>(id_it->second));

  EnterCriticalSection(&io_lock_);
  auto pit = pending_.find(id);
  if (pit != pending_.end() && pit->second) {
    auto* p = pit->second;
    auto ok_it = root.find(flutter::EncodableValue("ok"));
    p->ok = ok_it != root.end() && std::holds_alternative<bool>(ok_it->second) &&
            std::get<bool>(ok_it->second);
    auto err_it = root.find(flutter::EncodableValue("error"));
    if (err_it != root.end() && std::holds_alternative<std::string>(err_it->second))
      p->error = std::get<std::string>(err_it->second);
    auto res_it = root.find(flutter::EncodableValue("result"));
    if (res_it != root.end()) p->result = res_it->second;
    SetEvent(p->event);
  }
  LeaveCriticalSection(&io_lock_);
}

bool KotvWinChrome::CallRemote(const std::string& method, const EncodableMap* args, EncodableValue* out,
                               std::string* err) {
  if (!EnsureProcess() || !stdin_wr_) {
    if (err) *err = "win7 chrome process unavailable";
    return false;
  }
  const int64_t id = NextId();
  Pending pending;
  pending.event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  EnterCriticalSection(&io_lock_);
  pending_[id] = &pending;
  LeaveCriticalSection(&io_lock_);

  flutter::EncodableMap msg;
  msg[flutter::EncodableValue("id")] = id;
  msg[flutter::EncodableValue("method")] = method;
  if (args) msg[flutter::EncodableValue("args")] = *args;
  else msg[flutter::EncodableValue("args")] = flutter::EncodableMap{};

  std::string line = EncodeJson(msg) + "\n";
  DWORD written = 0;
  BOOL wok = WriteFile(stdin_wr_, line.data(), static_cast<DWORD>(line.size()), &written, nullptr);
  if (!wok) {
    EnterCriticalSection(&io_lock_);
    pending_.erase(id);
    LeaveCriticalSection(&io_lock_);
    CloseHandle(pending.event);
    if (err) *err = "write failed";
    return false;
  }

  const DWORD wait = WaitForSingleObject(pending.event, 8000);
  EnterCriticalSection(&io_lock_);
  pending_.erase(id);
  LeaveCriticalSection(&io_lock_);
  CloseHandle(pending.event);

  if (wait != WAIT_OBJECT_0) {
    if (err) *err = "timeout";
    return false;
  }
  if (!pending.ok) {
    if (err) *err = pending.error.empty() ? "remote error" : pending.error;
    return false;
  }
  if (out) *out = pending.result;
  return true;
}

void KotvWinChrome::HandleMethod(const std::string& method, const EncodableMap* args,
                                 std::function<void(EncodableValue)> success,
                                 std::function<void(const std::string&, const std::string&)> error) {
  EncodableMap forwarded;
  if (args) forwarded = *args;

  // 把 Flutter HWND 交给 WPF，用于贴客户区
  if (method == "setEnabled" || method == "update") {
    HWND hwnd = FlutterHwnd();
    if (hwnd) {
      forwarded[EncodableValue("hostHwnd")] =
          EncodableValue(static_cast<int64_t>(reinterpret_cast<intptr_t>(hwnd)));
    }
  }

  if (method == "setEnabled") {
    const bool en =
        args && args->count(EncodableValue("enabled")) &&
        std::holds_alternative<bool>(args->at(EncodableValue("enabled"))) &&
        std::get<bool>(args->at(EncodableValue("enabled")));
    if (!en) {
      // 关壳：通知远端后可保留进程，加快下次打开
      EncodableValue out;
      std::string err;
      CallRemote(method, &forwarded, &out, &err);
      success(EncodableValue(true));
      return;
    }
  }

  EncodableValue out;
  std::string err;
  if (!CallRemote(method, &forwarded, &out, &err)) {
    // 进程缺失时降级：避免整页卡死
    if (method == "setEnabled" || method == "update" || method == "setDanmaku" ||
        method == "showSheet" || method == "hideSheet") {
      success(EncodableValue(false));
      return;
    }
    error("win7_chrome", err);
    return;
  }
  success(out);
}

// ---------------------------------------------------------------------------
// Plugin
// ---------------------------------------------------------------------------

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
