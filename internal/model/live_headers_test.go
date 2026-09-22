package model

import "testing"

func TestBuildHeadersChannelOnly(t *testing.T) {
	live := &Live{
		Header: map[string]string{"X-Live": "1"},
		UA:     "LiveUA",
	}
	ch := &LiveChannel{
		Live:   live,
		Header: map[string]string{"X-Chan": "2"},
		UA:     "ChanUA",
	}
	h := ch.BuildHeaders()
	if _, ok := h["X-Live"]; ok {
		t.Fatalf("BuildHeaders must not merge Live.Header when channel has its own: %v", h)
	}
	if h["X-Chan"] != "2" {
		t.Fatalf("channel header missing: %v", h)
	}
	if h["User-Agent"] != "ChanUA" {
		t.Fatalf("UA want ChanUA got %q", h["User-Agent"])
	}
}

func TestBuildHeadersInheritViaApplyLive(t *testing.T) {
	live := &Live{
		Header:  map[string]string{"X-Live": "1"},
		UA:      "LiveUA",
		Referer: "http://live.ref/",
		Origin:  "http://live.origin/",
	}
	ch := &LiveChannel{Live: live}
	ch.ApplyLive(live)
	h := ch.BuildHeaders()
	if h["X-Live"] != "1" {
		t.Fatalf("after ApplyLive, channel should own live header: %v", h)
	}
	if h["User-Agent"] != "LiveUA" {
		t.Fatalf("UA want LiveUA got %q", h["User-Agent"])
	}
	if h["Referer"] != "http://live.ref/" {
		t.Fatalf("Referer got %q", h["Referer"])
	}
	if h["Origin"] != "http://live.origin/" {
		t.Fatalf("Origin got %q", h["Origin"])
	}
}

func TestBuildHeadersEmptyChannelKeepsNoLiveMap(t *testing.T) {
	live := &Live{Header: map[string]string{"X-Live": "1"}}
	ch := &LiveChannel{
		Live:   live,
		Header: map[string]string{"X-Chan": "2"},
	}
	// 未走 ApplyLive：频道已有 header，不应再并入源级 map。
	h := ch.BuildHeaders()
	if _, ok := h["X-Live"]; ok {
		t.Fatalf("unexpected Live.Header merge: %v", h)
	}
	if h["X-Chan"] != "2" {
		t.Fatalf("channel header: %v", h)
	}
}
