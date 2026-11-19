package database

import (
	"fmt"
	"path/filepath"
	"testing"
	"time"
)

func TestMigrateAdminGroupsDefault(t *testing.T) {
	db, err := OpenPath(filepath.Join(t.TempDir(), "admin.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	groups, err := db.ListAuthGroups()
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, g := range groups {
		if g.ID == DefaultGroupID {
			found = true
		}
	}
	if !found {
		t.Fatal("default group missing after migrate")
	}

	if err := db.InsertUsageEvent(UsageEvent{
		At: time.Now().UnixMilli(), UserID: "u1", GroupID: DefaultGroupID,
		Kind: "play", RefID: "s/1", OK: true,
	}); err != nil {
		t.Fatal(err)
	}
	sum, err := db.StatsSummary(time.Now().Add(-time.Hour).UnixMilli(), time.Now().Add(time.Hour).UnixMilli(), "", "")
	if err != nil {
		t.Fatal(err)
	}
	if sum["plays"].(int) < 1 {
		t.Fatalf("plays=%v", sum["plays"])
	}

	g2 := AuthGroup{ID: "g-test", Name: "测试", Enabled: true, CreatedAt: time.Now().UTC()}
	if err := db.UpsertAuthGroup(g2); err != nil {
		t.Fatal(err)
	}
	if err := db.SetGroupVods("g-test", []int64{1, 2}); err != nil {
		t.Fatal(err)
	}
	ids, _ := db.ListGroupVodIDs("g-test")
	if len(ids) != 2 {
		t.Fatalf("vod ids %v", ids)
	}
}

// 回归：已有点播仓时 ensureDefaultGroup 边扫边写曾在 MaxOpenConns=1 下死锁。
func TestEnsureDefaultGroupWithExistingVods(t *testing.T) {
	path := filepath.Join(t.TempDir(), "admin-vods.db")
	db, err := OpenPath(path)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		if _, err := db.UpsertConfig(&Config{Type: ConfigTypeSite, URL: fmt.Sprintf("http://example.test/%d", i)}); err != nil {
			t.Fatal(err)
		}
	}
	_ = db.Close()

	done := make(chan error, 1)
	go func() {
		db2, err := OpenPath(path)
		if err != nil {
			done <- err
			return
		}
		defer db2.Close()
		ids, err := db2.ListGroupVodIDs(DefaultGroupID)
		if err != nil {
			done <- err
			return
		}
		if len(ids) < 3 {
			done <- fmt.Errorf("group_vod count=%d", len(ids))
			return
		}
		done <- nil
	}()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("ensureDefaultGroup deadlocked on existing vod configs")
	}
}
