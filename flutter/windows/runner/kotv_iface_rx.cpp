// 独立编译单元：必须在任何 Flutter/Win32 头之前设定版本宏并按序包含
// winsock2 → iphlpapi，否则 GetIfTable2 / MIB_IF_TABLE2 在 runner 里常「未声明」
//（flutter_window.cpp 先吃进 Flutter 头后，再 include iphlpapi 会踩坑）。

#ifndef WINVER
#define WINVER 0x0601
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#endif
#ifndef NTDDI_VERSION
#define NTDDI_VERSION 0x06010000
#endif

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>

#include <cstdint>

#include "kotv_iface_rx.h"

#pragma comment(lib, "iphlpapi.lib")
#pragma comment(lib, "ws2_32.lib")

int64_t KotvInterfaceRxBytes() {
  PMIB_IF_TABLE2 table = nullptr;
  if (GetIfTable2(&table) != NO_ERROR || table == nullptr) {
    return -1;
  }
  uint64_t total = 0;
  for (ULONG i = 0; i < table->NumEntries; ++i) {
    const MIB_IF_ROW2& row = table->Table[i];
    if (row.Type == IF_TYPE_SOFTWARE_LOOPBACK) {
      continue;
    }
    total += row.InOctets;
  }
  FreeMibTable(table);
  return static_cast<int64_t>(total);
}
