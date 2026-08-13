package config

import (
	"os"
	"testing"

	"github.com/bobo/KOTV/internal/database"
	"github.com/bobo/KOTV/internal/settings"
)

// TestMain 统一设置一个稳定的 KOTV_DATA_DIR：database.Open 是包级单例，
// 若每个测试各用 t.TempDir() 会在第二个测试里指向已清理的目录导致只读报错。
func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "kotv_config_test")
	if err != nil {
		panic(err)
	}
	os.Setenv("KOTV_DATA_DIR", dir)
	code := m.Run()
	os.RemoveAll(dir)
	os.Unsetenv("KOTV_DATA_DIR")
	os.Exit(code)
}

// 回归：粘贴两份不同的 JSON 仓库源，应当各自成为独立源（追加），
// 而不是第二个覆盖第一个。修复前两份都会写成 inline://vod 同一键导致覆盖。
func TestAddInlineSourcesAppend(t *testing.T) {
	db, err := database.Open()
	if err != nil {
		t.Fatal(err)
	}
	db.ClearConfigs()
	m := NewManager(db)

	const jsonA = `{"name":"仓库A","sites":[{"key":"a1","name":"站点A","type":1,"api":"x","playUrl":""}]}`
	const jsonB = `{"name":"仓库B","sites":[{"key":"b1","name":"站点B","type":1,"api":"y","playUrl":""}]}`

	if err := m.LoadFromSource(jsonA); err != nil {
		t.Fatalf("load A: %v", err)
	}
	if err := m.LoadFromSource(jsonB); err != nil {
		t.Fatalf("load B: %v", err)
	}

	cfgs, err := db.ListConfigs(database.ConfigTypeSite)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("rows after 2 inline adds = %d", len(cfgs))
	if len(cfgs) != 2 {
		t.Fatalf("期望 2 个独立仓库源(追加)，实际 %d 个(第二个覆盖了第一个)", len(cfgs))
	}

	// 同一份 JSON 再次加载应幂等（仍是 2 行，不重复）。
	if err := m.LoadFromSource(jsonA); err != nil {
		t.Fatalf("reload A: %v", err)
	}
	cfgs2, _ := db.ListConfigs(database.ConfigTypeSite)
	if len(cfgs2) != 2 {
		t.Fatalf("幂等加载后期望仍为 2 行，实际 %d 行", len(cfgs2))
	}
}

// 回归：只给接口、sites 为空的源（如 spider-api 类）也必须落盘，
// 对齐 TV 的“空 sites 也照常入库”行为。修复前会 return error 导致整行不写，
// 表现就是“添加第二个仓库源根本不落盘”。
func TestLoadEmptySitesPersists(t *testing.T) {
	db, err := database.Open()
	if err != nil {
		t.Fatal(err)
	}
	db.ClearConfigs()
	m := NewManager(db)

	const emptySites = `{"name":"空站点源","sites":[]}`
	if err := m.LoadFromSource(emptySites); err != nil {
		t.Fatalf("空 sites 源应当落盘，但却报错: %v", err)
	}

	cfgs, err := db.ListConfigs(database.ConfigTypeSite)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("rows after empty-sites add = %d", len(cfgs))
	if len(cfgs) != 1 {
		t.Fatalf("期望空 sites 源也落盘为 1 行，实际 %d 行(未落盘)", len(cfgs))
	}
	// 当前源应指向该 URL（inline://hash），证明已设为激活源。
	cur := settings.Get(settings.VOD)
	if cur == "" {
		t.Fatalf("当前源(VOD)未设置")
	}
	t.Logf("current VOD = %s", cur)
}
