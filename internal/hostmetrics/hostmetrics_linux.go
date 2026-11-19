//go:build linux

package hostmetrics

import (
	"bufio"
	"os"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

func fillLoad(s *Snapshot) {
	b, err := os.ReadFile("/proc/loadavg")
	if err != nil {
		return
	}
	parts := strings.Fields(string(b))
	if len(parts) < 3 {
		return
	}
	s.Load1, _ = strconv.ParseFloat(parts[0], 64)
	s.Load5, _ = strconv.ParseFloat(parts[1], 64)
	s.Load15, _ = strconv.ParseFloat(parts[2], 64)
}

func fillHostMem(s *Snapshot) {
	f, err := os.Open("/proc/meminfo")
	if err != nil {
		return
	}
	defer f.Close()
	vals := map[string]uint64{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		parts := strings.Fields(line)
		if len(parts) < 2 {
			continue
		}
		key := strings.TrimSuffix(parts[0], ":")
		n, _ := strconv.ParseUint(parts[1], 10, 64)
		vals[key] = n * 1024 // kB → bytes
	}
	s.MemTotal = vals["MemTotal"]
	s.MemAvailable = vals["MemAvailable"]
	if s.MemAvailable == 0 {
		s.MemAvailable = vals["MemFree"] + vals["Buffers"] + vals["Cached"]
	}
	if s.MemTotal >= s.MemAvailable {
		s.MemUsed = s.MemTotal - s.MemAvailable
	}
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
	// /proc/self/status VmRSS
	b, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return
	}
	for _, line := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(line, "VmRSS:") {
			fields := strings.Fields(line)
			if len(fields) >= 2 {
				n, _ := strconv.ParseUint(fields[1], 10, 64)
				s.ProcRSS = n * 1024
			}
			return
		}
	}
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
	b, err := os.ReadFile("/proc/net/dev")
	if err != nil {
		return
	}
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "Inter") || strings.HasPrefix(line, "face") {
			continue
		}
		// eth0: recv ... sent ...
		parts := strings.Fields(strings.ReplaceAll(line, ":", " "))
		if len(parts) < 10 {
			continue
		}
		name := parts[0]
		if name == "lo" {
			continue
		}
		recv, _ := strconv.ParseUint(parts[1], 10, 64)
		sent, _ := strconv.ParseUint(parts[9], 10, 64)
		s.NetBytesRecv += recv
		s.NetBytesSent += sent
	}
}
