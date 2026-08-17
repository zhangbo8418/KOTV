package m3u8

import (
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestNoDiscontinuityUnchanged(t *testing.T) {
	in := `#EXTM3U
#EXTINF:3.0,
https://cdn.com/a.ts
#EXTINF:3.0,
https://cdn.com/b.ts
#EXT-X-ENDLIST
`
	out := NewFilter(DefaultConfig()).Process(in)
	if out != in {
		t.Fatalf("expected unchanged without DISCONTINUITY")
	}
}

func TestKeepsNonNumericHashNames(t *testing.T) {
	// 旧序号法会在这种哈希名上乱砍；新规则应按时长保留正片。
	in := `#EXTM3U
#EXTINF:4.0,
https://cdn.com/vod/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.ts
#EXTINF:4.0,
https://cdn.com/vod/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.ts
#EXTINF:4.0,
https://cdn.com/vod/cccccccccccccccccccccccccccccccc.ts
#EXT-X-DISCONTINUITY
#EXTINF:2.0,
https://cdn.com/ad/x1.ts
#EXTINF:2.0,
https://cdn.com/ad/x2.ts
#EXTINF:2.0,
https://cdn.com/ad/x3.ts
#EXTINF:2.0,
https://cdn.com/ad/x4.ts
#EXTINF:2.0,
https://cdn.com/ad/x5.ts
#EXT-X-DISCONTINUITY
#EXTINF:4.0,
https://cdn.com/vod/dddddddddddddddddddddddddddddddd.ts
#EXTINF:4.0,
https://cdn.com/vod/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee.ts
#EXTINF:4.0,
https://cdn.com/vod/ffffffffffffffffffffffffffffffff.ts
#EXTINF:4.0,
https://cdn.com/vod/gggggggggggggggggggggggggggggggg.ts
#EXTINF:4.0,
https://cdn.com/vod/hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh.ts
#EXTINF:4.0,
https://cdn.com/vod/iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii.ts
#EXTINF:4.0,
https://cdn.com/vod/jjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjj.ts
#EXTINF:4.0,
https://cdn.com/vod/kkkkkkkkkkkkkkkkkkkkkkkkkkkkkkkk.ts
#EXTINF:4.0,
https://cdn.com/vod/llllllllllllllllllllllllllllllll.ts
#EXTINF:4.0,
https://cdn.com/vod/mmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmm.ts
#EXTINF:4.0,
https://cdn.com/vod/nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn.ts
#EXTINF:4.0,
https://cdn.com/vod/oooooooooooooooooooooooooooooooo.ts
#EXTINF:4.0,
https://cdn.com/vod/pppppppppppppppppppppppppppppppp.ts
#EXTINF:4.0,
https://cdn.com/vod/qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq.ts
#EXTINF:4.0,
https://cdn.com/vod/rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr.ts
#EXTINF:4.0,
https://cdn.com/vod/ssssssssssssssssssssssssssssssss.ts
#EXT-X-ENDLIST
`
	// 中间广告：齐 EXTINF、总和 10s 边界——用 2*4=8s 明确短突发
	in = strings.Replace(in, `#EXTINF:2.0,
https://cdn.com/ad/x1.ts
#EXTINF:2.0,
https://cdn.com/ad/x2.ts
#EXTINF:2.0,
https://cdn.com/ad/x3.ts
#EXTINF:2.0,
https://cdn.com/ad/x4.ts
#EXTINF:2.0,
https://cdn.com/ad/x5.ts`, `#EXTINF:2.0,
https://cdn.com/ad/x1.ts
#EXTINF:2.0,
https://cdn.com/ad/x2.ts
#EXTINF:2.0,
https://cdn.com/ad/x3.ts
#EXTINF:2.0,
https://cdn.com/ad/x4.ts`, 1)

	f := NewFilter(FilterConfig{KeepMinDuration: 60, UniformShortMax: 10, MaxRemoveDuration: 120, UseLastModified: false})
	out := f.Process(in)
	if strings.Contains(out, "/ad/") {
		t.Fatalf("ad path not removed:\n%s", out)
	}
	if countSegments(out) < 15 {
		t.Fatalf("content over-removed: segs=%d removedDur=%.1f reverted=%v\n%s", countSegments(out), f.RemovedDuration(), f.Reverted(), out)
	}
}

func TestRemovesUniformShortBurst(t *testing.T) {
	in := `#EXTM3U
#EXTINF:5.0,
https://cdn.com/v/hash_aaa.ts
#EXTINF:5.0,
https://cdn.com/v/hash_bbb.ts
#EXT-X-DISCONTINUITY
#EXTINF:1.5,
https://cdn.com/p/ad1.ts
#EXTINF:1.5,
https://cdn.com/p/ad2.ts
#EXTINF:1.5,
https://cdn.com/p/ad3.ts
#EXTINF:1.5,
https://cdn.com/p/ad4.ts
#EXT-X-DISCONTINUITY
#EXTINF:5.0,
https://cdn.com/v/hash_ccc.ts
#EXTINF:5.0,
https://cdn.com/v/hash_ddd.ts
#EXTINF:5.0,
https://cdn.com/v/hash_eee.ts
#EXTINF:5.0,
https://cdn.com/v/hash_fff.ts
#EXTINF:5.0,
https://cdn.com/v/hash_ggg.ts
#EXTINF:5.0,
https://cdn.com/v/hash_hhh.ts
#EXTINF:5.0,
https://cdn.com/v/hash_iii.ts
#EXTINF:5.0,
https://cdn.com/v/hash_jjj.ts
#EXTINF:5.0,
https://cdn.com/v/hash_kkk.ts
#EXTINF:5.0,
https://cdn.com/v/hash_lll.ts
#EXTINF:5.0,
https://cdn.com/v/hash_mmm.ts
#EXTINF:5.0,
https://cdn.com/v/hash_nnn.ts
#EXT-X-ENDLIST
`
	f := NewFilter(FilterConfig{KeepMinDuration: 60, UniformShortMax: 10, MaxRemoveDuration: 120, UseLastModified: false})
	out := f.Process(in)
	if strings.Contains(out, "ad1.ts") || strings.Contains(out, "ad4.ts") {
		t.Fatalf("uniform short ad not removed:\n%s", out)
	}
	if !strings.Contains(out, "hash_aaa") || !strings.Contains(out, "hash_nnn") {
		t.Fatalf("content missing:\n%s", out)
	}
}

func TestRevertWhenRemoveTooMuch(t *testing.T) {
	var b strings.Builder
	b.WriteString("#EXTM3U\n")
	for i := 0; i < 5; i++ {
		fmt.Fprintf(&b, "#EXTINF:3.0,\nhttps://cdn.com/v/%d.ts\n", i)
	}
	// 多个「齐短」段组，累计删除 > 120s → 回滚
	for g := 0; g < 20; g++ {
		b.WriteString("#EXT-X-DISCONTINUITY\n")
		for j := 0; j < 5; j++ {
			fmt.Fprintf(&b, "#EXTINF:2.0,\nhttps://cdn.com/x/g%d_%d.ts\n", g, j)
		}
	}
	b.WriteString("#EXT-X-ENDLIST\n")
	in := b.String()
	f := NewFilter(FilterConfig{KeepMinDuration: 60, UniformShortMax: 15, MaxRemoveDuration: 120, UseLastModified: false})
	out := f.Process(in)
	if !f.Reverted() {
		t.Fatalf("expected revert, removedDur=%.1f groups=%d", f.RemovedDuration(), f.RemovedGroups())
	}
	if out != in {
		t.Fatalf("reverted filter must return original")
	}
}

func TestLastModifiedCluster(t *testing.T) {
	in := `#EXTM3U
#EXTINF:10.0,
https://cdn.com/v/a.ts
#EXTINF:10.0,
https://cdn.com/v/b.ts
#EXTINF:10.0,
https://cdn.com/v/c.ts
#EXTINF:10.0,
https://cdn.com/v/d.ts
#EXTINF:10.0,
https://cdn.com/v/e.ts
#EXTINF:10.0,
https://cdn.com/v/f.ts
#EXTINF:10.0,
https://cdn.com/v/g.ts
#EXT-X-DISCONTINUITY
#EXTINF:8.0,
https://cdn.com/p/ad.ts
#EXTINF:8.0,
https://cdn.com/p/ad2.ts
#EXT-X-DISCONTINUITY
#EXTINF:10.0,
https://cdn.com/v/h.ts
#EXTINF:10.0,
https://cdn.com/v/i.ts
#EXTINF:10.0,
https://cdn.com/v/j.ts
#EXTINF:10.0,
https://cdn.com/v/k.ts
#EXTINF:10.0,
https://cdn.com/v/l.ts
#EXTINF:10.0,
https://cdn.com/v/m.ts
#EXTINF:10.0,
https://cdn.com/v/n.ts
#EXT-X-ENDLIST
`
	main := time.Date(2026, 1, 10, 12, 0, 0, 0, time.UTC)
	ad := time.Date(2024, 6, 1, 0, 0, 0, 0, time.UTC)
	lms := []time.Time{main, ad, main}
	f := NewFilter(FilterConfig{KeepMinDuration: 60, UniformShortMax: 5, MaxRemoveDuration: 120, UseLastModified: true})
	out := f.Process(in, lms...)
	if strings.Contains(out, "/p/ad") {
		t.Fatalf("LM ad not removed:\n%s", out)
	}
	if countSegments(out) < 12 {
		t.Fatalf("over-removed: %d", countSegments(out))
	}
}

func TestStrongAdPath(t *testing.T) {
	in := `#EXTM3U
#EXTINF:30.0,
https://cdn.com/v/a.ts
#EXTINF:30.0,
https://cdn.com/v/b.ts
#EXT-X-DISCONTINUITY
#EXTINF:20.0,
https://cdn.com/adjump/x.ts
#EXTINF:20.0,
https://cdn.com/adjump/y.ts
#EXT-X-DISCONTINUITY
#EXTINF:30.0,
https://cdn.com/v/c.ts
#EXTINF:30.0,
https://cdn.com/v/d.ts
#EXT-X-ENDLIST
`
	f := NewFilter(FilterConfig{KeepMinDuration: 60, UniformShortMax: 5, MaxRemoveDuration: 120, UseLastModified: false})
	out := f.Process(in)
	if strings.Contains(out, "adjump") {
		t.Fatalf("strong path ad kept:\n%s", out)
	}
}

func TestMildOnlyStripsDiscontinuity(t *testing.T) {
	in := `#EXTM3U
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-DISCONTINUITY
#EXTINF:2.0,
https://cdn.com/v/a.ts
#EXT-X-DISCONTINUITY
#EXTINF:2.0,
https://cdn.com/ad/b.ts
#EXT-X-ENDLIST
`
	f := NewFilter(FilterConfig{Mode: ModeMild})
	out := f.Apply(in)
	if !f.UsedMild() {
		t.Fatal("expected usedMild")
	}
	if strings.Contains(out, "#EXT-X-DISCONTINUITY\n#EXTINF:2.0,\nhttps://cdn.com/ad") {
		t.Fatalf("mid discontinuity should be stripped:\n%s", out)
	}
	// PLAYLIST-TYPE 后的 DISCONTINUITY 保留
	if !strings.Contains(out, "#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-DISCONTINUITY") {
		t.Fatalf("playlist-type discontinuity should keep:\n%s", out)
	}
	// 切片都在
	if !strings.Contains(out, "a.ts") || !strings.Contains(out, "ad/b.ts") {
		t.Fatalf("mild must keep all segments:\n%s", out)
	}
}

func TestSmartFallsBackToMildWhenNoStructureHit(t *testing.T) {
	// 有 DISCONTINUITY，但段组都较长且 EXTINF 不齐短 → 结构不过滤，智能档应温和去断点。
	in := `#EXTM3U
#EXTINF:10.0,
https://cdn.com/v/a.ts
#EXTINF:10.0,
https://cdn.com/v/b.ts
#EXTINF:10.0,
https://cdn.com/v/c.ts
#EXTINF:10.0,
https://cdn.com/v/d.ts
#EXTINF:10.0,
https://cdn.com/v/e.ts
#EXTINF:10.0,
https://cdn.com/v/f.ts
#EXT-X-DISCONTINUITY
#EXTINF:10.0,
https://cdn.com/v/g.ts
#EXTINF:12.0,
https://cdn.com/v/h.ts
#EXTINF:11.0,
https://cdn.com/v/i.ts
#EXTINF:10.0,
https://cdn.com/v/j.ts
#EXTINF:10.0,
https://cdn.com/v/k.ts
#EXTINF:10.0,
https://cdn.com/v/l.ts
#EXT-X-ENDLIST
`
	f := NewFilter(FilterConfig{
		Mode:              ModeSmart,
		KeepMinDuration:   60,
		UniformShortMax:   5,
		MaxRemoveDuration: 120,
		UseLastModified:   false,
	})
	out := f.Apply(in)
	if !f.UsedMild() {
		t.Fatal("expected mild fallback")
	}
	if strings.Contains(out, "#EXT-X-DISCONTINUITY") {
		t.Fatalf("discontinuity should be stripped by mild fallback:\n%s", out)
	}
	if countSegments(out) != countSegments(in) {
		t.Fatalf("segments changed: before=%d after=%d", countSegments(in), countSegments(out))
	}
}

func TestSmartKeepsStructureResultWithoutMild(t *testing.T) {
	in := `#EXTM3U
#EXTINF:5.0,
https://cdn.com/v/hash_aaa.ts
#EXTINF:5.0,
https://cdn.com/v/hash_bbb.ts
#EXT-X-DISCONTINUITY
#EXTINF:1.5,
https://cdn.com/p/ad1.ts
#EXTINF:1.5,
https://cdn.com/p/ad2.ts
#EXTINF:1.5,
https://cdn.com/p/ad3.ts
#EXTINF:1.5,
https://cdn.com/p/ad4.ts
#EXT-X-DISCONTINUITY
#EXTINF:5.0,
https://cdn.com/v/hash_ccc.ts
#EXTINF:5.0,
https://cdn.com/v/hash_ddd.ts
#EXTINF:5.0,
https://cdn.com/v/hash_eee.ts
#EXTINF:5.0,
https://cdn.com/v/hash_fff.ts
#EXTINF:5.0,
https://cdn.com/v/hash_ggg.ts
#EXTINF:5.0,
https://cdn.com/v/hash_hhh.ts
#EXTINF:5.0,
https://cdn.com/v/hash_iii.ts
#EXTINF:5.0,
https://cdn.com/v/hash_jjj.ts
#EXTINF:5.0,
https://cdn.com/v/hash_kkk.ts
#EXTINF:5.0,
https://cdn.com/v/hash_lll.ts
#EXTINF:5.0,
https://cdn.com/v/hash_mmm.ts
#EXTINF:5.0,
https://cdn.com/v/hash_nnn.ts
#EXT-X-ENDLIST
`
	f := NewFilter(FilterConfig{
		Mode:              ModeSmart,
		KeepMinDuration:   60,
		UniformShortMax:   10,
		MaxRemoveDuration: 120,
		UseLastModified:   false,
	})
	out := f.Apply(in)
	if f.UsedMild() {
		t.Fatal("structure hit should not fall back to mild")
	}
	if strings.Contains(out, "ad1.ts") {
		t.Fatalf("ad should be removed by structure:\n%s", out)
	}
}
