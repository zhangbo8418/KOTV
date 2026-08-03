package server

import (
	"reflect"
	"testing"
)

func TestPostMsgPerClient(t *testing.T) {
	e := NewEvents()
	e.EmitPostMsgTo("a1", "client-a")
	e.EmitPostMsgTo("b1", "client-b")
	e.EmitPostMsgTo("a2", "client-a")

	gotA := e.DrainPostMsg("client-a")
	if !reflect.DeepEqual(gotA, []string{"a1", "a2"}) {
		t.Fatalf("client-a got %#v", gotA)
	}
	gotB := e.DrainPostMsg("client-b")
	if !reflect.DeepEqual(gotB, []string{"b1"}) {
		t.Fatalf("client-b got %#v", gotB)
	}
	if len(e.DrainPostMsg("client-a")) != 0 {
		t.Fatal("expected empty after drain")
	}
}

func TestPostMsgBroadcastUntagged(t *testing.T) {
	e := NewEvents()
	// register clients via poll
	_ = e.DrainPostMsg("c1")
	_ = e.DrainPostMsg("c2")
	e.EmitPostMsgTo("toast", "")
	got1 := e.DrainPostMsg("c1")
	got2 := e.DrainPostMsg("c2")
	if !reflect.DeepEqual(got1, []string{"toast"}) {
		t.Fatalf("c1 %#v", got1)
	}
	if !reflect.DeepEqual(got2, []string{"toast"}) {
		t.Fatalf("c2 %#v", got2)
	}
}
