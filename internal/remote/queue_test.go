package remote

import "testing"

func TestPushOpenDrain(t *testing.T) {
	q := &Queue{byClient: map[string]*clientBucket{}, known: map[string]struct{}{}}
	q.PushOpen(OpenCmd{Kind: "play", Site: "push_agent", ID: "http://a", URL: "http://a", Name: "A"}, "c1")
	q.PushOpen(OpenCmd{Kind: "detail", Site: "site", ID: "1", Name: "B"}, "c1")
	_, _, _, _, opens := q.Drain("c1")
	if len(opens) != 2 {
		t.Fatalf("opens=%d want 2", len(opens))
	}
	if opens[0].Kind != "play" || opens[1].Kind != "detail" {
		t.Fatalf("unexpected opens: %+v", opens)
	}
	_, _, _, _, opens = q.Drain("c1")
	if len(opens) != 0 {
		t.Fatalf("second drain should be empty, got %d", len(opens))
	}
}

func TestPushRefreshLiveEmptyPath(t *testing.T) {
	q := &Queue{byClient: map[string]*clientBucket{}, known: map[string]struct{}{}}
	q.PushRefresh("live", "", "c1")
	q.PushRefresh("subtitle", "", "c1")
	_, _, refs, _, _ := q.Drain("c1")
	if len(refs) != 1 || refs[0].Type != "live" {
		t.Fatalf("refs=%+v want single live", refs)
	}
}
