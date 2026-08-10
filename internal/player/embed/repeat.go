//go:build cgo

package embed

import "sync/atomic"

// 单集循环（对齐 TV ExoPlayer REPEAT_MODE_ONE）。
var repeatOne atomic.Bool

// IsRepeatOne 当前是否单集循环。
func IsRepeatOne() bool { return repeatOne.Load() }

// SetRepeatOne 开关单集循环；MPV 立即生效。
func SetRepeatOne(on bool) {
	prev := repeatOne.Swap(on)
	if prev == on {
		return
	}
	applyRepeatOne(on)
}

// ToggleRepeatOne 翻转单集循环，返回开启后的状态。
func ToggleRepeatOne() bool {
	on := !IsRepeatOne()
	SetRepeatOne(on)
	return on
}

func applyRepeatOne(on bool) {
	if on {
		_ = mpvSetPropString("loop-file", "inf")
	} else {
		_ = mpvSetPropString("loop-file", "no")
	}
}
