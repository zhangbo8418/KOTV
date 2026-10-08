package service

import (
	"testing"
	"time"

	"github.com/bobo/KOTV/internal/model"
)

func TestSearchFirstExactReturnsBeforeSlowSite(t *testing.T) {
	fast := model.Site{Key: "fast", Name: "快"}
	slow := model.Site{Key: "slow", Name: "慢"}
	locked := model.Site{Key: "locked", Name: "关", QuickSearch: model.FlexInt{Valid: true, Value: 0}}
	current := model.Site{Key: "cur", Name: "当前"}
	start := time.Now()
	vod, ok := searchFirstExact(
		[]model.Site{locked, current, slow, fast},
		"片名",
		"cur",
		"1",
		func(site model.Site, keyword string) ([]model.Vod, error) {
			if site.Key == "locked" {
				t.Errorf("quickSearch 不是 1 的站不应被搜索")
			}
			if keyword != "片名" {
				t.Errorf("keyword=%q", keyword)
			}
			if site.Key == "slow" {
				time.Sleep(2 * time.Second)
			}
			id := "9"
			if site.Key == "cur" {
				id = "1"
			}
			return []model.Vod{{
				VodID:   model.FlexString(id),
				VodName: " 片名 ",
			}}, nil
		},
	)
	if time.Since(start) >= time.Second {
		t.Fatalf("waited %s for other sites", time.Since(start))
	}
	if !ok || vod.VodID.String() != "9" || vod.Site == nil || vod.Site.Key != "fast" {
		t.Fatalf("got ok=%v vod=%+v site=%v", ok, vod, vod.Site)
	}
}

func TestSearchFirstExactSkipsCurrentAndNonQuick(t *testing.T) {
	cur := model.Site{Key: "cur", Name: "当前"}
	off := model.Site{Key: "off", Name: "关", Changeable: model.FlexInt{Valid: true, Value: 2}}
	vod, ok := searchFirstExact([]model.Site{cur, off}, "片名", "cur", "1", func(site model.Site, keyword string) ([]model.Vod, error) {
		if site.Key != "cur" {
			t.Errorf("searched %s", site.Key)
		}
		return []model.Vod{{VodID: "1", VodName: keyword}}, nil
	})
	if ok || vod.VodID.String() != "" {
		t.Fatalf("current item must not be returned, ok=%v id=%s", ok, vod.VodID.String())
	}
}

func TestIsQuickSearchUnsetDefaultsOn(t *testing.T) {
	if !(model.Site{}).IsQuickSearch() {
		t.Fatal("unset quickSearch should search")
	}
	if (model.Site{QuickSearch: model.FlexInt{Valid: true, Value: 0}}).IsQuickSearch() {
		t.Fatal("quickSearch 0 should be off")
	}
	if !(model.Site{QuickSearch: model.FlexInt{Valid: true, Value: 1}}).IsQuickSearch() {
		t.Fatal("quickSearch 1 should be on")
	}
}
