//go:build windows

package hostmetrics

import (
	"os"
	"path/filepath"
	"syscall"
	"time"
	"unsafe"
)

func fillLoad(s *Snapshot) {
	// Windows 无 loadavg
}

func fillHostMem(s *Snapshot) {
	type memStatusEx struct {
		Length               uint32
		MemoryLoad           uint32
		TotalPhys            uint64
		AvailPhys            uint64
		TotalPageFile        uint64
		AvailPageFile        uint64
		TotalVirtual         uint64
		AvailVirtual         uint64
		AvailExtendedVirtual uint64
	}
	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	proc := kernel32.NewProc("GlobalMemoryStatusEx")
	var ms memStatusEx
	ms.Length = uint32(unsafe.Sizeof(ms))
	r, _, _ := proc.Call(uintptr(unsafe.Pointer(&ms)))
	if r == 0 {
		return
	}
	s.MemTotal = ms.TotalPhys
	s.MemAvailable = ms.AvailPhys
	if s.MemTotal >= s.MemAvailable {
		s.MemUsed = s.MemTotal - s.MemAvailable
	}
}

func fillDisk(s *Snapshot, path string) {
	path = filepath.VolumeName(path)
	if path == "" {
		wd, _ := os.Getwd()
		path = filepath.VolumeName(wd)
	}
	if path != "" && !stringsHasSlash(path) {
		path += `\`
	}
	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	proc := kernel32.NewProc("GetDiskFreeSpaceExW")
	var freeBytes, totalBytes, totalFree uint64
	p, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return
	}
	r, _, _ := proc.Call(
		uintptr(unsafe.Pointer(p)),
		uintptr(unsafe.Pointer(&freeBytes)),
		uintptr(unsafe.Pointer(&totalBytes)),
		uintptr(unsafe.Pointer(&totalFree)),
	)
	if r == 0 {
		return
	}
	s.DiskTotal = totalBytes
	s.DiskFree = freeBytes
	if totalBytes >= freeBytes {
		s.DiskUsed = totalBytes - freeBytes
	}
}

func stringsHasSlash(s string) bool {
	return len(s) > 0 && (s[len(s)-1] == '\\' || s[len(s)-1] == '/')
}

func fillProcRSS(s *Snapshot) {
	// WorkingSetSize via GetProcessMemoryInfo
	psapi := syscall.NewLazyDLL("psapi.dll")
	proc := psapi.NewProc("GetProcessMemoryInfo")
	type processMemoryCounters struct {
		CB                         uint32
		PageFaultCount             uint32
		PeakWorkingSetSize         uintptr
		WorkingSetSize             uintptr
		QuotaPeakPagedPoolUsage    uintptr
		QuotaPagedPoolUsage        uintptr
		QuotaPeakNonPagedPoolUsage uintptr
		QuotaNonPagedPoolUsage     uintptr
		PagefileUsage              uintptr
		PeakPagefileUsage          uintptr
	}
	var pmc processMemoryCounters
	pmc.CB = uint32(unsafe.Sizeof(pmc))
	h, err := syscall.GetCurrentProcess()
	if err != nil {
		return
	}
	r, _, _ := proc.Call(uintptr(h), uintptr(unsafe.Pointer(&pmc)), uintptr(pmc.CB))
	if r != 0 {
		s.ProcRSS = uint64(pmc.WorkingSetSize)
	}
}

func procCPUTimes() (user, sys time.Duration, ok bool) {
	var creation, exit, kernel, userT syscall.Filetime
	h, err := syscall.GetCurrentProcess()
	if err != nil {
		return 0, 0, false
	}
	if err := syscall.GetProcessTimes(h, &creation, &exit, &kernel, &userT); err != nil {
		return 0, 0, false
	}
	return filetimeToDuration(userT), filetimeToDuration(kernel), true
}

func filetimeToDuration(ft syscall.Filetime) time.Duration {
	ns := int64(ft.HighDateTime)<<32 + int64(ft.LowDateTime)
	// 100ns units
	return time.Duration(ns * 100)
}

func fillNetIO(s *Snapshot) {}
