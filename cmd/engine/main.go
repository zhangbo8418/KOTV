// Engine 无 UI 入口：供 Flutter / 自动化联调使用。
// 启动后提供 :9978 HTTP（含 /api/v1 与既有 /proxy/*）。
package main

import (
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/bobo/KOTV/internal/app"
	"github.com/bobo/KOTV/internal/remote"
)

func main() {
	remote.WireFlutterBridge()
	a, err := app.New()
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("KOTV engine ready http://127.0.0.1:%d (api=/api/v1)", a.Server.Port())
	if a.ErrMsg != "" {
		log.Printf("config: %s", a.ErrMsg)
	}

	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
	sig := <-ch
	log.Printf("engine stopping: %v", sig)
}
