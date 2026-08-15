package spider

import (
	"net/url"
	"os"
	"path/filepath"
	"testing"
)

func TestCacheJarLocalFile(t *testing.T) {
	dir := t.TempDir()
	jar := filepath.Join(dir, "spider.jar")
	// 超过 downloadBinary 的 64 字节门槛；本地直载也要非空。
	payload := make([]byte, 128)
	for i := range payload {
		payload[i] = byte(i)
	}
	if err := os.WriteFile(jar, payload, 0o644); err != nil {
		t.Fatal(err)
	}
	raw := (&url.URL{Scheme: "file", Path: filepath.ToSlash(jar)}).String()
	got, err := cacheJar(raw, "", false)
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Clean(got) != filepath.Clean(jar) {
		t.Fatalf("got %q want %q", got, jar)
	}

	// 相对本地配置目录
	cfg := filepath.Join(dir, "config.json")
	if err := os.WriteFile(cfg, []byte(`{}`), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err = cacheJar("spider.jar", "file://"+filepath.ToSlash(cfg), false)
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Clean(got) != filepath.Clean(jar) {
		t.Fatalf("relative got %q want %q", got, jar)
	}
}
