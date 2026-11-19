//go:build darwin

package hostmetrics

import (
	"time"

	"golang.org/x/sys/unix"
)

func fillLoad(s *Snapshot) {
	// vm.loadavg → struct { fixpt_t ldavg[3]; long fscale; }
	raw, err := unix.SysctlRaw("vm.loadavg")
	if err != nil || len(raw) < 16 {
		return
	}
	// Darwin LP64: 3×uint32 + pad + int64 scale（常见 24 字节）
	var load [3]uint32
	var scale uint64
	if len(raw) >= 24 {
		load[0] = uint32(raw[0]) | uint32(raw[1])<<8 | uint32(raw[2])<<16 | uint32(raw[3])<<24
		load[1] = uint32(raw[4]) | uint32(raw[5])<<8 | uint32(raw[6])<<16 | uint32(raw[7])<<24
		load[2] = uint32(raw[8]) | uint32(raw[9])<<8 | uint32(raw[10])<<16 | uint32(raw[11])<<24
		for i := 0; i < 8; i++ {
			scale |= uint64(raw[16+i]) << (8 * i)
		}
	} else {
		return
	}
	if scale == 0 {
		return
	}
	s.Load1 = float64(load[0]) / float64(scale)
	s.Load5 = float64(load[1]) / float64(scale)
	s.Load15 = float64(load[2]) / float64(scale)
}

func fillHostMem(s *Snapshot) {
	total, err := unix.SysctlUint64("hw.memsize")
	if err != nil || total == 0 {
		return
	}
	s.MemTotal = total
	page := uint64(unix.Getpagesize())
	// 现代 macOS 页计数多为 32-bit；inactive 等 oid 已移除，改用 external/pageable。
	availPages := sysctlU32("vm.page_free_count") +
		sysctlU32("vm.page_speculative_count") +
		sysctlU32("vm.page_purgeable_count") +
		sysctlU32("vm.page_pageable_external_count")
	avail := availPages * page
	if avail > total {
		avail = total
	}
	s.MemAvailable = avail
	s.MemUsed = total - avail
}

func sysctlU32(name string) uint64 {
	v, err := unix.SysctlUint32(name)
	if err != nil {
		return 0
	}
	return uint64(v)
}

func fillDisk(s *Snapshot, path string) {
	var st unix.Statfs_t
	if err := unix.Statfs(path, &st); err != nil {
		return
	}
	bsize := uint64(st.Bsize)
	s.DiskTotal = st.Blocks * bsize
	s.DiskFree = st.Bavail * bsize
	if s.DiskTotal >= s.DiskFree {
		s.DiskUsed = s.DiskTotal - s.DiskFree
	}
}

func fillProcRSS(s *Snapshot) {
	var ru unix.Rusage
	if err := unix.Getrusage(unix.RUSAGE_SELF, &ru); err != nil {
		return
	}
	// Darwin Maxrss 单位为字节
	s.ProcRSS = uint64(ru.Maxrss)
}

func procCPUTimes() (user, sys time.Duration, ok bool) {
	var ru unix.Rusage
	if err := unix.Getrusage(unix.RUSAGE_SELF, &ru); err != nil {
		return 0, 0, false
	}
	return time.Duration(ru.Utime.Sec)*time.Second + time.Duration(ru.Utime.Usec)*time.Microsecond,
		time.Duration(ru.Stime.Sec)*time.Second + time.Duration(ru.Stime.Usec)*time.Microsecond,
		true
}

func fillNetIO(s *Snapshot) {
	// macOS 无稳定无特权接口；仪表以 HTTP 连接数为主，字节吞吐留空。
}
