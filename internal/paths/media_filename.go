package paths

import (
	"path/filepath"
	"strings"
)

// 对齐 bridge Util.MEDIA / csp_Local.categoryContent。
var mediaExt = map[string]struct{}{
	".mp4": {}, ".mkv": {}, ".mov": {}, ".m4v": {}, ".webm": {}, ".wmv": {}, ".flv": {},
	".avi": {}, ".iso": {}, ".mpg": {}, ".mpeg": {}, ".ts": {}, ".m2ts": {},
	".mp3": {}, ".aac": {}, ".flac": {}, ".m4a": {}, ".ape": {}, ".ogg": {}, ".wav": {}, ".wma": {},
	".rm": {}, ".rmvb": {}, ".asf": {}, ".dts": {}, ".dsf": {}, ".dff": {}, ".m3u8": {}, ".mpd": {},
}

// IsMediaFilename 按扩展名判断是否为本地可播媒体（忽略大小写）。
func IsMediaFilename(name string) bool {
	ext := strings.ToLower(filepath.Ext(strings.TrimSpace(name)))
	if ext == "" {
		return false
	}
	_, ok := mediaExt[ext]
	return ok
}
