//go:build !windows && !darwin

package resources

import _ "embed"

// AppIconPNG 默认应用图标（Linux 等）。
//
//go:embed icons/kotv-icon.png
var AppIconPNG []byte
