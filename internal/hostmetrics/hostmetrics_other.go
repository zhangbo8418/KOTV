//go:build !darwin && !linux && !windows

package hostmetrics

import "time"

func fillLoad(s *Snapshot)     {}
func fillHostMem(s *Snapshot)  {}
func fillDisk(s *Snapshot, _ string) {}
func fillProcRSS(s *Snapshot)  {}
func fillNetIO(s *Snapshot)    {}

func procCPUTimes() (user, sys time.Duration, ok bool) {
	return 0, 0, false
}
