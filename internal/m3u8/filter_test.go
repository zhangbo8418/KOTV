package m3u8

import (
	"fmt"
	"strings"
	"testing"
)

func TestMediaBaseIgnoresHostTs(t *testing.T) {
	u := "https://cdn123.ts.com/vod/00042.ts?token=1"
	if got := mediaBase(u); got != "00042.ts" {
		t.Fatalf("mediaBase=%q", got)
	}
	n, ok := extractNumberBeforeTs(u)
	if !ok || n != 42 {
		t.Fatalf("extractNumberBeforeTs=%d ok=%v want 42", n, ok)
	}
	if tsPrefixLen(u) != len("00042") {
		t.Fatalf("tsPrefixLen=%d", tsPrefixLen(u))
	}
}

func TestFilterKeepsContentWhenHostContainsTs(t *testing.T) {
	// 旧逻辑对整 URL 做 (\d+)\.ts，会匹配主机名 cdn01.ts.com → 序号恒为 1，正片几乎删光。
	var b strings.Builder
	b.WriteString("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n")
	for i := 1; i <= 40; i++ {
		b.WriteString("#EXTINF:3.0,\n")
		fmt.Fprintf(&b, "https://cdn01.ts.com/film/%03d.ts\n", i)
	}
	b.WriteString("#EXT-X-ENDLIST\n")
	out := NewFilter(DefaultConfig()).Process(b.String())
	segs := countSegments(out)
	if segs < 35 {
		t.Fatalf("kept %d segments, filter likely mis-read host as ts index:\n%s", segs, out)
	}
}

func TestFilterStillDropsAdByNameLength(t *testing.T) {
	in := `#EXTM3U
#EXTINF:2.0,
https://cdn.com/v/01.ts
#EXTINF:2.0,
https://cdn.com/v/02.ts
#EXT-X-DISCONTINUITY
#EXTINF:2.0,
https://cdn.com/ad/verylongadname.ts
#EXT-X-DISCONTINUITY
#EXTINF:2.0,
https://cdn.com/v/03.ts
#EXT-X-ENDLIST
`
	out := NewFilter(DefaultConfig()).Process(in)
	if strings.Contains(out, "verylongadname") {
		t.Fatalf("ad segment not filtered:\n%s", out)
	}
	if countSegments(out) != 3 {
		t.Fatalf("want 3 content segs, got %d:\n%s", countSegments(out), out)
	}
}
