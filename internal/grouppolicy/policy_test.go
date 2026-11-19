package grouppolicy

import (
	"testing"
	"time"

	"github.com/bobo/KOTV/internal/auth"
	"github.com/bobo/KOTV/internal/model"
)

func TestFilterRepoMapsAndSites(t *testing.T) {
	b := Bundle{
		VodURLs:  map[string]struct{}{"http://a": {}},
		SiteHide: map[string]struct{}{"bad": {}},
	}
	repos := []map[string]any{
		{"url": "http://a"},
		{"url": "http://b"},
	}
	out := b.FilterRepoMaps(repos)
	if len(out) != 1 {
		t.Fatalf("want 1 repo, got %d", len(out))
	}
	sites := []model.Site{{Key: "ok"}, {Key: "bad"}}
	fs := b.FilterSites(sites)
	if len(fs) != 1 || fs[0].Key != "ok" {
		t.Fatalf("site filter: %+v", fs)
	}
	b.IsAdmin = true
	if len(b.FilterSites(sites)) != 2 {
		t.Fatal("admin should see all sites")
	}
}

func TestAccessDenyMaintenance(t *testing.T) {
	b := Bundle{Maintenance: true, MaintMsg: "维护"}
	reason, code := b.AccessDeny(&auth.User{Status: "active", Enabled: true}, "1.2.3.4")
	if code != "maintenance" || reason != "维护" {
		t.Fatalf("got %q %q", reason, code)
	}
	b.IsAdmin = true
	if r, c := b.AccessDeny(&auth.User{Role: auth.RoleAdmin}, "1.2.3.4"); r != "" || c != "" {
		t.Fatalf("admin should pass: %q %q", r, c)
	}
}

func TestAccessDenyPending(t *testing.T) {
	b := Bundle{}
	reason, code := b.AccessDeny(&auth.User{Status: "pending", Enabled: true}, "")
	if code != "pending" {
		t.Fatalf("want pending, got %s %s", code, reason)
	}
}

func TestDeviceAndSessionLimit(t *testing.T) {
	b := Bundle{Settings: map[string]string{"maxDevices": "3", "maxSessions": "2"}}
	if b.DeviceLimit() != 3 || b.SessionLimit() != 2 {
		t.Fatalf("limits %d %d", b.DeviceLimit(), b.SessionLimit())
	}
}

func TestDayTimeInRange(t *testing.T) {
	if !dayInRange(3, "1-5") {
		t.Fatal("wed in 1-5")
	}
	now := time.Date(2026, 1, 1, 12, 0, 0, 0, time.Local)
	if !timeInRange(now, "09:00-18:00") {
		t.Fatal("noon in range")
	}
	if timeInRange(now, "18:00-22:00") {
		t.Fatal("noon should be out")
	}
}
