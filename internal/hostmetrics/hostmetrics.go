// Package hostmetrics 采集本机/进程资源摘要，供管理台概览仪表使用。
package hostmetrics

import (
	"os"
	"runtime"
	"sync"
	"sync/atomic"
	"time"
)

// Snapshot 一次采样结果。
type Snapshot struct {
	At           int64   `json:"at"`
	UptimeSec    int64   `json:"uptimeSec"`
	GoVersion    string  `json:"goVersion"`
	GOOS         string  `json:"goos"`
	GOARCH       string  `json:"goarch"`
	NumCPU       int     `json:"numCPU"`
	Goroutines   int     `json:"goroutines"`
	Load1        float64 `json:"load1"`
	Load5        float64 `json:"load5"`
	Load15       float64 `json:"load15"`
	CPUPercent   float64 `json:"cpuPercent"` // 进程 CPU%，约 0–100*NumCPU
	MemTotal     uint64  `json:"memTotal"`
	MemUsed      uint64  `json:"memUsed"`
	MemAvailable uint64  `json:"memAvailable"`
	MemPercent   float64 `json:"memPercent"`
	ProcRSS      uint64  `json:"procRSS"`
	HeapInuse    uint64  `json:"heapInuse"`
	HeapSys      uint64  `json:"heapSys"`
	DiskPath     string  `json:"diskPath"`
	DiskTotal    uint64  `json:"diskTotal"`
	DiskUsed     uint64  `json:"diskUsed"`
	DiskFree     uint64  `json:"diskFree"`
	DiskPercent  float64 `json:"diskPercent"`
	NetBytesSent uint64  `json:"netBytesSent"`
	NetBytesRecv uint64  `json:"netBytesRecv"`
	HTTPConns    int64   `json:"httpConns"` // 引擎 HTTP 活跃连接
}

var (
	startedAt = time.Now()
	cpuMu     sync.Mutex
	cpuLast   cpuSample
	httpConns atomic.Int64
)

type cpuSample struct {
	wall time.Time
	user time.Duration
	sys  time.Duration
	ok   bool
}

// IncHTTPConn / DecHTTPConn 由 server 在 ConnState 回调里调用。
func IncHTTPConn() { httpConns.Add(1) }
func DecHTTPConn() {
	for {
		n := httpConns.Load()
		if n <= 0 {
			httpConns.Store(0)
			return
		}
		if httpConns.CompareAndSwap(n, n-1) {
			return
		}
	}
}
func HTTPConnCount() int64 {
	n := httpConns.Load()
	if n < 0 {
		return 0
	}
	return n
}

// Collect diskPath 用于磁盘占用（一般传 paths.Root()）。
func Collect(diskPath string) Snapshot {
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)

	if diskPath == "" {
		diskPath, _ = os.Getwd()
	}

	s := Snapshot{
		At:         time.Now().UnixMilli(),
		UptimeSec:  int64(time.Since(startedAt).Seconds()),
		GoVersion:  runtime.Version(),
		GOOS:       runtime.GOOS,
		GOARCH:     runtime.GOARCH,
		NumCPU:     runtime.NumCPU(),
		Goroutines: runtime.NumGoroutine(),
		HeapInuse:  ms.HeapInuse,
		HeapSys:    ms.HeapSys,
		DiskPath:   diskPath,
		HTTPConns:  HTTPConnCount(),
	}
	fillLoad(&s)
	fillHostMem(&s)
	fillProcRSS(&s)
	fillDisk(&s, diskPath)
	fillNetIO(&s)
	s.CPUPercent = sampleProcCPU()
	if s.MemTotal > 0 && s.MemUsed == 0 && s.MemAvailable > 0 && s.MemAvailable <= s.MemTotal {
		s.MemUsed = s.MemTotal - s.MemAvailable
	}
	if s.MemTotal > 0 {
		s.MemPercent = float64(s.MemUsed) * 100 / float64(s.MemTotal)
	}
	if s.DiskTotal > 0 {
		s.DiskPercent = float64(s.DiskUsed) * 100 / float64(s.DiskTotal)
	}
	return s
}

func sampleProcCPU() float64 {
	user, sys, ok := procCPUTimes()
	now := time.Now()
	cpuMu.Lock()
	defer cpuMu.Unlock()
	if !ok {
		return 0
	}
	if !cpuLast.ok {
		cpuLast = cpuSample{wall: now, user: user, sys: sys, ok: true}
		return 0
	}
	wall := now.Sub(cpuLast.wall).Seconds()
	cpu := (user - cpuLast.user + sys - cpuLast.sys).Seconds()
	cpuLast = cpuSample{wall: now, user: user, sys: sys, ok: true}
	if wall <= 0 {
		return 0
	}
	pct := cpu / wall * 100
	if pct < 0 {
		return 0
	}
	max := float64(runtime.NumCPU()) * 100
	if pct > max {
		pct = max
	}
	return pct
}
