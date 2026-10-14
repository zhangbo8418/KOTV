package parse_test

import (
	"testing"

	"github.com/bobo/KOTV/internal/model"
	"github.com/bobo/KOTV/internal/parse"
)

func TestResolveWithParses_SkipsSpecialSource(t *testing.T) {
	r := model.Result{
		Parse: model.FlexInt{Valid: true, Value: 1},
		Flag:  "qq",
		URL:   model.URL{URLs: []string{"https://www.youtube.com/watch?v=dQw4w9WgXcQ"}},
	}
	out, err := parse.ResolveWithParses(r, parse.Options{
		Parses: []model.Parse{{Name: "jx", Type: model.FlexInt{Valid: true, Value: 1}, URL: "http://example/jx?url="}},
		Flags:  []string{"qq"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !out.Parse.Is(0) {
		t.Fatalf("special source must force parse=0, got %#v", out.Parse)
	}
	if out.URL.URLs[0] != r.URL.URLs[0] {
		t.Fatalf("url rewritten by parse: %q", out.URL.URLs[0])
	}
}
