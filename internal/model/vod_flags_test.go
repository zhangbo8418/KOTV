package model

import "testing"

func TestSetVodFlags_KeepsDuplicateNamesSkipsEmptyURL(t *testing.T) {
	v := &Vod{
		VodPlayFrom: "线路A$$$线路A$$$线路B$$$线路C",
		VodPlayURL:  "1$http://a/1$$$1$http://a2/1$$$$$$1$http://c/1",
	}
	v.SetVodFlags()
	if len(v.VodFlags) != 3 {
		t.Fatalf("flags=%d %+v", len(v.VodFlags), v.VodFlags)
	}
	if v.VodFlags[0].Flag != "线路A" || v.VodFlags[1].Flag != "线路A" || v.VodFlags[2].Flag != "线路C" {
		t.Fatalf("flags=%+v", v.VodFlags)
	}
	if v.VodFlags[1].Episodes[0].URL != "http://a2/1" {
		t.Fatalf("second 线路A lost: %+v", v.VodFlags[1])
	}
}

func TestFlagFind_ScoreRules(t *testing.T) {
	f := CreateFlag("x")
	f.CreateEpisode("第01集$u1#第02集$u2#花絮特辑$u3#片头曲$u4")

	// 100：同名
	if ep := f.Find("第02集", true); ep == nil || ep.URL != "u2" {
		t.Fatalf("rule1 got %+v", ep)
	}
	// 80：数字相同
	if ep := f.Find("2", true); ep == nil || ep.URL != "u2" {
		t.Fatalf("rule2 got %+v", ep)
	}
	// 70：备注被集名包含（备注 ≥2 字）
	if ep := f.Find("花絮", true); ep == nil || ep.URL != "u3" {
		t.Fatalf("rule3 got %+v", ep)
	}
	// 1 字备注不走包含匹配
	if ep := f.Find("曲", true); ep != nil {
		t.Fatalf("single char must not match, got %+v", ep)
	}
	// 60：集名被备注包含
	if ep := f.Find("正在播放片头曲", true); ep == nil || ep.URL != "u4" {
		t.Fatalf("rule4 got %+v", ep)
	}
}
