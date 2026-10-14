package live

import (
	"testing"

	"github.com/bobo/KOTV/internal/model"
)

func TestResolvePlayURLParsed_MatchSkipsNeedParse(t *testing.T) {
	s := NewService(nil)
	ch := &model.LiveChannel{
		Name:  "yt",
		Parse: 1,
		URLs:  []string{"https://www.youtube.com/watch?v=dQw4w9WgXcQ"},
	}
	out, _, err := s.ResolvePlayURLParsed(ch)
	if err != nil {
		t.Fatal(err)
	}
	if out != ch.URLs[0] {
		t.Fatalf("Match channel must keep url for later Fetch, got %q", out)
	}
}
