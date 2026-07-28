package main

import (
	"fmt"
	"log"
	"strings"
	"time"

	"github.com/bobo/KOTV/internal/config"
	"github.com/bobo/KOTV/internal/database"
	"github.com/bobo/KOTV/internal/parse"
	"github.com/bobo/KOTV/internal/service"
	"github.com/bobo/KOTV/internal/settings"
	"github.com/bobo/KOTV/internal/util"
)

func main() {
	_ = settings.Load()
	db, err := database.Open()
	if err != nil {
		log.Fatal(err)
	}
	m := config.NewManager(db)
	util.SetProxy(settings.Get(settings.Proxy))
	if err := m.InitFromSettings(); err != nil {
		log.Fatal(err)
	}
	sitesSvc := service.NewSiteService(m)
	tried := 0
	for _, site := range m.Sites() {
		if site.TypeID() != 3 || site.IsHide() {
			continue
		}
		n := strings.ToLower(site.Name + site.Key)
		if strings.Contains(n, "douban") || strings.Contains(n, "豆瓣") ||
			strings.Contains(n, "登录") || strings.Contains(n, "push") {
			continue
		}
		tried++
		if tried > 25 {
			break
		}
		m.SetHome(site)
		start := time.Now()
		home, err := sitesSvc.HomeContent()
		elapsed := time.Since(start).Round(time.Millisecond)
		if err != nil {
			fmt.Printf("%s HOME ERR (%s): %v\n", site.Key, elapsed, brief(err))
			continue
		}
		if len(home.List) == 0 {
			fmt.Printf("%s HOME OK (%s) list=0\n", site.Key, elapsed)
			continue
		}
		fmt.Printf("%s HOME OK (%s) list=%d\n", site.Key, elapsed, len(home.List))
		vod := home.List[0]
		start = time.Now()
		detail, err := sitesSvc.DetailContent(vod)
		elapsed = time.Since(start).Round(time.Millisecond)
		if err != nil {
			fmt.Printf("  detail ERR (%s): %v id=%s\n", elapsed, brief(err), vod.VodID)
			continue
		}
		eps := 0
		if len(detail.VodFlags) > 0 {
			eps = len(detail.VodFlags[0].Episodes)
		}
		fmt.Printf("  detail OK (%s) name=%s flags=%d eps0=%d\n", elapsed, detail.VodName, len(detail.VodFlags), eps)
		if eps == 0 {
			continue
		}
		ep := detail.VodFlags[0].Episodes[0]
		start = time.Now()
		pr, err := sitesSvc.PlayerContent(site, detail.VodFlags[0].Flag, ep.URL)
		elapsed = time.Since(start).Round(time.Millisecond)
		if err != nil {
			fmt.Printf("  player ERR (%s): %v\n", elapsed, brief(err))
			continue
		}
		u := parse.ResolvePlayURL("", pr.PlayURL, pr.URL.URLs)
		if u == "" {
			fmt.Printf("  player EMPTY (%s) parse=%v\n", elapsed, pr.Parse)
			continue
		}
		if len(u) > 120 {
			u = u[:120] + "…"
		}
		fmt.Printf("  player OK (%s): %s\n", elapsed, u)
		fmt.Println("SUCCESS site=", site.Key)
		return
	}
	fmt.Println("no working play site found")
}

func brief(err error) string {
	s := err.Error()
	if i := strings.Index(s, "\n"); i > 0 {
		s = s[:i]
	}
	if len(s) > 160 {
		s = s[:160] + "…"
	}
	return s
}
