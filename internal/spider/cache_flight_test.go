package spider

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/bobo/KOTV/internal/paths"
	"github.com/bobo/KOTV/internal/util"
)

func TestConcurrentCacheDownloadOnce(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("KOTV_DATA_DIR", dir)
	payload := make([]byte, 128)
	copy(payload, []byte("PK"))
	var calls atomic.Int32
	started := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := calls.Add(1)
		if n == 1 {
			once.Do(func() { close(started) })
			<-release
		}
		_, _ = w.Write(payload)
	}))
	defer srv.Close()

	jarURL := srv.URL + "/spider.jar"
	dest := paths.JarPath(util.MD5(jarURL))
	t.Cleanup(func() { _ = os.Remove(dest) })

	var wg sync.WaitGroup
	errCh := make(chan error, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := cacheJar(jarURL, "", false)
			errCh <- err
		}()
	}
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("jar 下载没有开始")
	}
	time.Sleep(80 * time.Millisecond)
	if got := calls.Load(); got != 1 {
		t.Fatalf("正在下载时又发出 %d 次 jar 请求", got)
	}
	close(release)
	wg.Wait()
	close(errCh)
	for err := range errCh {
		if err != nil {
			t.Fatal(err)
		}
	}

	pyBody := []byte("class Spider:\n    pass\n")
	var pyCalls atomic.Int32
	pyStarted := make(chan struct{})
	pyRelease := make(chan struct{})
	var pyOnce sync.Once
	pySrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := pyCalls.Add(1)
		if n == 1 {
			pyOnce.Do(func() { close(pyStarted) })
			<-pyRelease
		}
		_, _ = w.Write(pyBody)
	}))
	defer pySrv.Close()
	pyURL := pySrv.URL + "/site.py"
	pyDest := filepath.Join(paths.PyCache(), util.MD5(pyURL)+".py")
	t.Cleanup(func() { _ = os.Remove(pyDest) })

	errCh = make(chan error, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			s := &pySpider{api: pyURL}
			_, err := s.ensureScript()
			errCh <- err
		}()
	}
	select {
	case <-pyStarted:
	case <-time.After(5 * time.Second):
		t.Fatal("py 下载没有开始")
	}
	time.Sleep(80 * time.Millisecond)
	if got := pyCalls.Load(); got != 1 {
		t.Fatalf("正在下载时又发出 %d 次 py 请求", got)
	}
	close(pyRelease)
	wg.Wait()
	close(errCh)
	for err := range errCh {
		if err != nil {
			t.Fatal(err)
		}
	}
}
