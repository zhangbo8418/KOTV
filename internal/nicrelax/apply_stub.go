//go:build !linux

package nicrelax

import "errors"

// Apply 只在 Linux 上改网卡功能位。
func Apply() error {
	return errors.New("relax-nic only runs on linux")
}
