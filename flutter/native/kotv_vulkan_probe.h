// Windows / Linux 原生 MPV 共用：本机是否真有能跑 libplacebo 的 Vulkan GPU。
//
// 只看 loader（vulkan-1.dll / libvulkan.so.1）在不在不够：loader 常随别的软件装上，
// 显卡却没有 Vulkan 驱动或只到 1.0/1.1，mpv 试 gpu-api=vulkan 时会崩。
// 这里真建一次 instance 并枚举物理设备：要求 loader 与至少一块非 CPU 设备都 ≥ 1.2
// （libplacebo 的最低版本）。结果进程内缓存。
//
// 不依赖 Vulkan 头文件：只用 ABI 稳定的入口函数与结构体前几个字段。
#pragma once

#include <cstdint>
#include <cstring>

#ifdef _WIN32
#include <windows.h>
#define KOTV_VKAPI __stdcall
#else
#include <dlfcn.h>
#define KOTV_VKAPI
#endif

namespace kotv_vk {

constexpr uint32_t kApi12 = (1u << 22) | (2u << 12);

struct AppInfo {
  uint32_t sType;  // VK_STRUCTURE_TYPE_APPLICATION_INFO = 0
  const void* pNext;
  const char* pApplicationName;
  uint32_t applicationVersion;
  const char* pEngineName;
  uint32_t engineVersion;
  uint32_t apiVersion;
};

struct InstanceInfo {
  uint32_t sType;  // VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO = 1
  const void* pNext;
  uint32_t flags;
  const AppInfo* pApplicationInfo;
  uint32_t enabledLayerCount;
  const char* const* ppEnabledLayerNames;
  uint32_t enabledExtensionCount;
  const char* const* ppEnabledExtensionNames;
};

// VkPhysicalDeviceProperties 的开头；整体约 824 字节，取数据用足够大的缓冲。
struct PropsHead {
  uint32_t apiVersion;
  uint32_t driverVersion;
  uint32_t vendorID;
  uint32_t deviceID;
  int32_t deviceType;  // 1 集显 2 独显 3 虚拟 4 CPU
};

using GetInstanceProcAddr = void*(KOTV_VKAPI*)(void*, const char*);
using EnumerateInstanceVersion = int32_t(KOTV_VKAPI*)(uint32_t*);
using CreateInstance = int32_t(KOTV_VKAPI*)(const InstanceInfo*, const void*, void**);
using DestroyInstance = void(KOTV_VKAPI*)(void*, const void*);
using EnumeratePhysicalDevices = int32_t(KOTV_VKAPI*)(void*, uint32_t*, void**);
using GetPhysicalDeviceProperties = void(KOTV_VKAPI*)(void*, void*);

inline GetInstanceProcAddr LoadLoader() {
#ifdef _WIN32
  // 只认系统 loader；不卸载，部分 ICD 卸载时会崩。
  HMODULE h = LoadLibraryExW(L"vulkan-1.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
  return h ? reinterpret_cast<GetInstanceProcAddr>(GetProcAddress(h, "vkGetInstanceProcAddr"))
           : nullptr;
#else
  void* h = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
  return h ? reinterpret_cast<GetInstanceProcAddr>(dlsym(h, "vkGetInstanceProcAddr")) : nullptr;
#endif
}

inline bool ProbeUnguarded() {
  const GetInstanceProcAddr gipa = LoadLoader();
  if (!gipa) return false;
  auto enum_version = reinterpret_cast<EnumerateInstanceVersion>(
      gipa(nullptr, "vkEnumerateInstanceVersion"));
  uint32_t loader_version = 0;
  if (!enum_version || enum_version(&loader_version) != 0 || loader_version < kApi12) {
    return false;
  }
  auto create = reinterpret_cast<CreateInstance>(gipa(nullptr, "vkCreateInstance"));
  if (!create) return false;
  AppInfo app{0, nullptr, "KOTV", 1, "KOTV", 1, kApi12};
  InstanceInfo info{1, nullptr, 0, &app, 0, nullptr, 0, nullptr};
  void* instance = nullptr;
  if (create(&info, nullptr, &instance) != 0 || !instance) return false;

  auto destroy = reinterpret_cast<DestroyInstance>(gipa(instance, "vkDestroyInstance"));
  auto enum_devices =
      reinterpret_cast<EnumeratePhysicalDevices>(gipa(instance, "vkEnumeratePhysicalDevices"));
  auto get_props = reinterpret_cast<GetPhysicalDeviceProperties>(
      gipa(instance, "vkGetPhysicalDeviceProperties"));
  bool ok = false;
  uint32_t count = 0;
  if (enum_devices && get_props && enum_devices(instance, &count, nullptr) == 0 && count > 0) {
    void* devices[16] = {};
    if (count > 16) count = 16;
    const int32_t r = enum_devices(instance, &count, devices);
    // VK_INCOMPLETE(5)：超过 16 块时只看前 16 块。
    if (r == 0 || r == 5) {
      for (uint32_t i = 0; i < count && !ok; ++i) {
        alignas(16) unsigned char buf[4096];
        std::memset(buf, 0, sizeof(buf));
        get_props(devices[i], buf);
        PropsHead head;
        std::memcpy(&head, buf, sizeof(head));
        ok = head.apiVersion >= kApi12 && head.deviceType >= 1 && head.deviceType <= 3;
      }
    }
  }
  if (destroy) destroy(instance, nullptr);
  return ok;
}

#ifdef _WIN32
// SEH 里不能有需要析构的对象，故单独一层。
inline bool ProbeGuarded() {
  __try {
    return ProbeUnguarded();
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return false;
  }
}
#endif

}  // namespace kotv_vk

inline bool KotvVulkanUsable() {
  static const bool usable = [] {
#ifdef _WIN32
    return kotv_vk::ProbeGuarded();
#else
    return kotv_vk::ProbeUnguarded();
#endif
  }();
  return usable;
}
