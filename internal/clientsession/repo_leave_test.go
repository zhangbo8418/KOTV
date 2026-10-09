package clientsession

import "testing"

func TestNoteRepoSkipsBaseline(t *testing.T) {
	s := &Session{}
	s.SetRepoBaseline(map[string]struct{}{"http://host/vod": {}})
	s.NoteRepo("http://host/vod")
	s.NoteRepo("  http://remote/depot  ")
	s.NoteRepo("")
	got := s.AddedRepos()
	if _, ok := got["http://host/vod"]; ok {
		t.Fatal("baseline url was recorded as added")
	}
	if _, ok := got["http://remote/depot"]; !ok {
		t.Fatal("new url was not recorded")
	}
	if len(got) != 1 {
		t.Fatalf("added = %v", got)
	}
}

func TestURLsAddedBySessionKeepsCurrentAndShared(t *testing.T) {
	added := map[string]struct{}{
		"http://remote/a": {},
		"http://host/vod": {},
		"http://remote/b": {},
	}
	held := map[string]struct{}{"http://remote/b": {}}
	got := URLsAddedBySession(added, "http://host/vod", held)
	if len(got) != 1 || got[0] != "http://remote/a" {
		t.Fatalf("drop = %v", got)
	}
}
