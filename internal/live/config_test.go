package live

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/bobo/KOTV/internal/model"
)

func TestParseConfigMeta_RootSpiderAndNet(t *testing.T) {
	raw := `{"spider":"http://x/spider.jar","headers":[{"host":"*","header":{"X":"1"}}],"hosts":["a=1.1.1.1"],"lives":[{"name":"A","api":"csp_X","url":"http://u"}]}`
	meta, ok := ParseConfigMeta(raw)
	if !ok {
		t.Fatal("expected config meta")
	}
	if meta.Spider != "http://x/spider.jar" {
		t.Fatalf("spider=%q", meta.Spider)
	}
	if len(meta.Headers) == 0 || len(meta.Hosts) == 0 {
		t.Fatalf("headers/hosts missing: %s / %s", meta.Headers, meta.Hosts)
	}
	if len(meta.Lives) != 1 || meta.Lives[0].Name != "A" {
		t.Fatalf("lives=%+v", meta.Lives)
	}
	// 空 jar 继承在 Service.Load；此处只验解析。
	var probe map[string]json.RawMessage
	if err := json.Unmarshal([]byte(raw), &probe); err != nil {
		t.Fatal(err)
	}
	if _, ok := probe["proxy"]; ok {
		t.Fatal("fixture has no proxy")
	}
}

func TestParseConfigMeta_PlainM3UObjectRejected(t *testing.T) {
	// 单个频道 JSON 数组不是根配置对象
	if _, ok := ParseConfigMeta(`[{"name":"G","channel":[]}]`); ok {
		t.Fatal("array must not be config meta")
	}
}

func TestLoad_MsgError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"msg":"账号过期"}`))
	}))
	t.Cleanup(srv.Close)
	_, err := NewService(nil).Load(model.Live{Name: "t", URL: srv.URL})
	if err == nil || err.Error() != "账号过期" {
		t.Fatalf("err=%v", err)
	}
}

func TestLoad_StarWrappedTXT(t *testing.T) {
	plain := "G,#genre#\nC,http://x/c.m3u8\n"
	body := "AbCd1234**" + base64.StdEncoding.EncodeToString([]byte(plain))
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	got, err := NewService(nil).Load(model.Live{Name: "t", URL: srv.URL})
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Groups) != 1 || len(got.Groups[0].Channels) != 1 {
		t.Fatalf("groups=%+v", got.Groups)
	}
}

func TestLoad_UrlsDepotFirst(t *testing.T) {
	mux := http.NewServeMux()
	var realURL string
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	realURL = srv.URL + "/real"
	mux.HandleFunc("/index", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"urls":[{"name":"R","url":"` + realURL + `"}]}`))
	})
	mux.HandleFunc("/real", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("G,#genre#\nC,http://x/c.m3u8\n"))
	})
	got, err := NewService(nil).Load(model.Live{Name: "idx", URL: srv.URL + "/index"})
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Groups) != 1 || got.Groups[0].Channels[0].Name != "C" {
		t.Fatalf("got=%+v", got.Groups)
	}
}
