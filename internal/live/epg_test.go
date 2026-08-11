package live

import (
	"fmt"
	"testing"
	"time"

	"github.com/bobo/KOTV/internal/model"
)

func TestSplitEpgURLs(t *testing.T) {
	api, xmls := SplitEpgURLs("http://a/{date}.json,https://b/epg.xml.gz,https://c/guide.xml")
	if api != "http://a/{date}.json" {
		t.Fatalf("api=%q", api)
	}
	if len(xmls) != 2 || xmls[0] != "https://b/epg.xml.gz" || xmls[1] != "https://c/guide.xml" {
		t.Fatalf("xmls=%v", xmls)
	}
}

func TestMatchXMLTVDisplayNameAndIcon(t *testing.T) {
	st := time.Now().Add(time.Hour)
	et := st.Add(time.Hour)
	raw := fmt.Sprintf(`<?xml version="1.0"?>
<tv>
  <channel id="cctv1.cn">
    <display-name>CCTV-1</display-name>
    <icon src="https://example.com/cctv1.png"/>
  </channel>
  <programme start="%s +0800" stop="%s +0800" channel="cctv1.cn">
    <title>新闻联播</title>
  </programme>
</tv>`, st.Format("20060102150405"), et.Format("20060102150405"))
	ch := &model.LiveChannel{Name: "CCTV-1"}
	days, logo, err := matchXMLTVDays([]byte(raw), ch, "")
	if err != nil {
		t.Fatal(err)
	}
	if logo != "https://example.com/cctv1.png" {
		t.Fatalf("logo=%q", logo)
	}
	if len(days) == 0 || len(days[0].List) == 0 {
		t.Fatalf("days=%v", days)
	}
	if days[0].List[0].Title != "新闻联播" {
		t.Fatalf("title=%q", days[0].List[0].Title)
	}
}
