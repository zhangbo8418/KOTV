//go:build cgo

package embed

import "sync/atomic"

// 单集循环（对齐 TV ExoPlayer REPEAT_MODE_ONE）。
var repeatOne atomic.Bool

// IsRepeatOne 当前是否单集循环。
func IsRepeatOne() bool { return repeatOne.Load() }

// SetRepeatOne 开关单集循环；MPV 立即生效，VLC 通过 media 选项（必要时重载当前片源）。
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
	vlcSetRepeat(on)

	// VLC 的 input-repeat 绑在 media 上，运行中切换需重建。
	ctrl := Active()
	if _, isVLC := ctrl.(*Engine); !isVLC {
		return
	}
	if enh, ok := ctrl.(Enhanced); ok && ctrl.DurationMs() > 0 {
		_ = enh.Reload(true)
	}
}
