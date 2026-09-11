package hlsproxy

import "bytes"

// StripDisguisePrefix 去掉常见图片壳（正片伪装成 png/jpg/gif）。
func StripDisguisePrefix(data []byte) []byte {
	return stripDisguisePrefix(data)
}

func stripDisguisePrefix(data []byte) []byte {
	if len(data) < 16 {
		return data
	}
	if !(isPNG(data) || isJPEG(data) || isGIF(data)) {
		return data
	}
	if off := findMPEGTS(data); off > 0 {
		return data[off:]
	}
	if off := findMP4Ftyp(data); off >= 4 {
		return data[off-4:]
	}
	return data
}

func isPNG(b []byte) bool {
	return len(b) >= 8 && bytes.Equal(b[:8], []byte{0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a})
}

func isJPEG(b []byte) bool {
	return len(b) >= 3 && b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff
}

func isGIF(b []byte) bool {
	return len(b) >= 6 && (bytes.Equal(b[:6], []byte("GIF87a")) || bytes.Equal(b[:6], []byte("GIF89a")))
}

func findMPEGTS(data []byte) int {
	limit := len(data)
	if limit > 512*1024 {
		limit = 512 * 1024
	}
	for i := 0; i+188 <= limit; i++ {
		if data[i] != 0x47 {
			continue
		}
		if i+188 < limit && data[i+188] == 0x47 {
			if i+376 < limit && data[i+376] != 0x47 {
				continue
			}
			return i
		}
	}
	return -1
}

func findMP4Ftyp(data []byte) int {
	limit := len(data)
	if limit > 512*1024 {
		limit = 512 * 1024
	}
	ftyp := []byte("ftyp")
	idx := bytes.Index(data[:limit], ftyp)
	if idx < 4 {
		return -1
	}
	return idx
}
