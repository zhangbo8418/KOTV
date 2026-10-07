//go:build linux

package nicrelax

import (
	"errors"
	"fmt"
	"net"
	"strings"
	"unsafe"

	"golang.org/x/sys/unix"
)

// ifreq 联合体在 64 位内核上是 24 字节，在 32 位上是 16 字节。
const ifreqPad = 8 + int(unsafe.Sizeof(uintptr(0)))

type ethtoolValue struct {
	cmd  uint32
	data uint32
}

// 布局须与内核 ifreq 一致：网卡名后面是用户指针。
type ifreqData struct {
	name [unix.IFNAMSIZ]byte
	data unsafe.Pointer
	_    [ifreqPad]byte
}

type feature struct {
	get   uint32
	set   uint32
	label string
}

// Apply 关掉非回环网卡的发送校验卸载和 GSO。
// RK3399 gmac 在这两项打开时，重传的满尺寸 TCP 段校验错误，对端不确认，播放连接就停住。
func Apply() error {
	fd, err := unix.Socket(unix.AF_INET, unix.SOCK_DGRAM, 0)
	if err != nil {
		return err
	}
	defer unix.Close(fd)

	ifaces, err := net.Interfaces()
	if err != nil {
		return err
	}
	var lines []string
	var hard []error
	changed := false
	for _, ifi := range ifaces {
		if ifi.Flags&net.FlagLoopback != 0 {
			continue
		}
		line, ok, err := relaxOne(fd, ifi.Name)
		if line != "" {
			lines = append(lines, line)
		}
		if ok {
			changed = true
		}
		if err != nil {
			hard = append(hard, fmt.Errorf("%s: %w", ifi.Name, err))
		}
	}
	if len(lines) > 0 {
		fmt.Println(strings.Join(lines, "\n"))
	}
	if changed || len(hard) == 0 {
		return nil
	}
	return errors.Join(hard...)
}

func relaxOne(fd int, name string) (line string, changed bool, err error) {
	feats := []feature{
		{unix.ETHTOOL_GTXCSUM, unix.ETHTOOL_STXCSUM, "tx-csum"},
		{unix.ETHTOOL_GGSO, unix.ETHTOOL_SGSO, "gso"},
	}
	var notes []string
	var hard []error
	for _, feat := range feats {
		cur, getErr := ethGet(fd, name, feat.get)
		if getErr != nil {
			if unsupported(getErr) {
				continue
			}
			hard = append(hard, fmt.Errorf("%s: %w", feat.label, getErr))
			continue
		}
		if cur == 0 {
			notes = append(notes, feat.label+" already off")
			continue
		}
		if setErr := ethSet(fd, name, feat.set, 0); setErr != nil {
			if unsupported(setErr) {
				continue
			}
			hard = append(hard, fmt.Errorf("%s: %w", feat.label, setErr))
			continue
		}
		notes = append(notes, feat.label+" off")
		changed = true
	}
	if len(notes) > 0 {
		line = name + ": " + strings.Join(notes, ", ")
	}
	return line, changed, errors.Join(hard...)
}

func ethGet(fd int, name string, cmd uint32) (uint32, error) {
	v := ethtoolValue{cmd: cmd}
	if err := ethtoolIoctl(fd, name, &v); err != nil {
		return 0, err
	}
	return v.data, nil
}

func ethSet(fd int, name string, cmd, data uint32) error {
	v := ethtoolValue{cmd: cmd, data: data}
	return ethtoolIoctl(fd, name, &v)
}

func ethtoolIoctl(fd int, name string, v *ethtoolValue) error {
	if len(name) >= unix.IFNAMSIZ {
		return unix.EINVAL
	}
	req := ifreqData{data: unsafe.Pointer(v)}
	copy(req.name[:], name)
	_, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(fd), uintptr(unix.SIOCETHTOOL), uintptr(unsafe.Pointer(&req)))
	if errno != 0 {
		return errno
	}
	return nil
}

func unsupported(err error) bool {
	return errors.Is(err, unix.EOPNOTSUPP) || errors.Is(err, unix.ENOTSUP) || errors.Is(err, unix.EINVAL)
}
