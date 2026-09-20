package util

import (
	"bytes"
	"compress/flate"
	"compress/gzip"
	"compress/zlib"
	"io"
	"strings"
)

// DecodeContentEncoding ResponseInterceptor：gzip + Inflater(nowrap) deflate。
func DecodeContentEncoding(encoding string, body []byte) []byte {
	if len(body) == 0 {
		return body
	}
	switch strings.ToLower(strings.TrimSpace(encoding)) {
	case "gzip":
		r, err := gzip.NewReader(bytes.NewReader(body))
		if err != nil {
			return body
		}
		defer r.Close()
		if out, err := io.ReadAll(r); err == nil {
			return out
		}
	case "deflate":
		if out, err := inflateRaw(body); err == nil {
			return out
		}
		if r, err := zlib.NewReader(bytes.NewReader(body)); err == nil {
			out, err2 := io.ReadAll(r)
			r.Close()
			if err2 == nil {
				return out
			}
		}
	}
	return body
}

func inflateRaw(body []byte) ([]byte, error) {
	r := flate.NewReader(bytes.NewReader(body))
	defer r.Close()
	return io.ReadAll(r)
}

// StripDecodedContentHeaders 解压成功后去掉 Content-Encoding / Content-Length。
func StripDecodedContentHeaders(h map[string][]string, encoding string, decoded bool) {
	if !decoded || encoding == "" {
		return
	}
	deleteHeaderFold(h, "Content-Encoding")
	deleteHeaderFold(h, "Content-Length")
}

func deleteHeaderFold(h map[string][]string, key string) {
	for k := range h {
		if strings.EqualFold(k, key) {
			delete(h, k)
		}
	}
}
