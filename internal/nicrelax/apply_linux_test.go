//go:build linux

package nicrelax

import (
	"testing"
	"unsafe"
)

func TestIfreqDataMatchesKernel(t *testing.T) {
	got := unsafe.Sizeof(ifreqData{})
	want := uintptr(32)
	if unsafe.Sizeof(uintptr(0)) == 8 {
		want = 40
	}
	if got != want {
		t.Fatalf("ifreqData size %d, kernel ifreq is %d", got, want)
	}
}
