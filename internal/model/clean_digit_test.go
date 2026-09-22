package model

import (
	"strings"
	"testing"
)

func TestGetDigit(t *testing.T) {
	cases := []struct {
		in   string
		want int
	}{
		{"2024第02集", 2},
		{"S01E05", 5},
		{"1080P 第3集", 3},
		{"更新至20集", 20},
		{"01", 1},
		{"无", -1},
		{"EP12", 12},
		{"[BD]第08集", 8},
		{"(内嵌)第1集", 1},
	}
	for _, c := range cases {
		if got := GetDigit(c.in); got != c.want {
			t.Fatalf("GetDigit(%q)=%d want %d", c.in, got, c.want)
		}
	}
}

func TestCleanName(t *testing.T) {
	if got := CleanName("A&amp;B<br>C"); got != "A&BC" {
		t.Fatalf("CleanName got %q", got)
	}
	if got := CleanName("纯文本"); got != "纯文本" {
		t.Fatalf("plain got %q", got)
	}
}

func TestCleanDesc(t *testing.T) {
	got := CleanDesc("上<br>下&amp;完")
	want := "上\n下&完"
	if got != want {
		t.Fatalf("CleanDesc got %q want %q", got, want)
	}
	got = CleanDesc("一行</p>二行")
	if !strings.Contains(got, "一行") || !strings.Contains(got, "二行") || !strings.Contains(got, "\n") {
		t.Fatalf("CleanDesc p-tag got %q", got)
	}
}

func TestDecodeResultJSON_CleansName(t *testing.T) {
	r, err := DecodeResultJSON(`{"list":[{"vod_id":"1","vod_name":"A&amp;B"}]}`)
	if err != nil {
		t.Fatal(err)
	}
	if r.List[0].VodName != "A&B" {
		t.Fatalf("vod_name=%q", r.List[0].VodName)
	}
}
