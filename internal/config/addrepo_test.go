package config

import (
	"os"
	"testing"

	"github.com/bobo/KOTV/internal/database"
)

// 回归：粘贴两份不同的 JSON 仓库源，应当各自成为独立源（追加），
// 而不是第二个覆盖第一个。修复前两份都会写成 inline://vod 同一键导致覆盖。
func TestAddInlineSourcesAppend(t *testing.T) {
	dir := t.TempDir()
	os.Setenv("KOTV_DATA_DIR", dir)
	defer os.Unsetenv("KOTV_DATA_DIR")

	db, err := database.Open()
	if err != nil {
		t.Fatal(err)
	}
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
