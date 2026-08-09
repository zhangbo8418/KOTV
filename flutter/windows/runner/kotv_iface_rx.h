#ifndef RUNNER_KOTV_IFACE_RX_H_
#define RUNNER_KOTV_IFACE_RX_H_

#include <cstdint>

// 网卡累计下行字节（跳过 loopback）。独立实现见 kotv_iface_rx.cpp。
int64_t KotvInterfaceRxBytes();

#endif  // RUNNER_KOTV_IFACE_RX_H_
