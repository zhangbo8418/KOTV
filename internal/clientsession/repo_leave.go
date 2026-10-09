package clientsession

import "strings"

// SetRepoBaseline 记下会话创建时已经在库里的仓库地址。之后再写入的才算本会话新增。
func (s *Session) SetRepoBaseline(urls map[string]struct{}) {
	if s == nil {
		return
	}
	s.repoMu.Lock()
	defer s.repoMu.Unlock()
	s.repoAtStart = urls
	if s.addedRepos == nil {
		s.addedRepos = map[string]struct{}{}
	}
}

// NoteRepo 记录本会话新写入、且创建时还不存在的仓库地址。
func (s *Session) NoteRepo(url string) {
	if s == nil {
		return
	}
	url = strings.TrimSpace(url)
	if url == "" {
		return
	}
	s.repoMu.Lock()
	defer s.repoMu.Unlock()
	if _, ok := s.repoAtStart[url]; ok {
		return
	}
	if s.addedRepos == nil {
		s.addedRepos = map[string]struct{}{}
	}
	s.addedRepos[url] = struct{}{}
}

// AddedRepos 返回本会话新增的仓库地址副本。
func (s *Session) AddedRepos() map[string]struct{} {
	if s == nil {
		return nil
	}
	s.repoMu.Lock()
	defer s.repoMu.Unlock()
	out := make(map[string]struct{}, len(s.addedRepos))
	for u := range s.addedRepos {
		out[u] = struct{}{}
	}
	return out
}

// URLsAddedBySession 挑出离开时应删除的地址：本会话新增、不是本机当前源、别的会话也没记下。
func URLsAddedBySession(added map[string]struct{}, keep string, stillHeld map[string]struct{}) []string {
	keep = strings.TrimSpace(keep)
	var out []string
	for u := range added {
		u = strings.TrimSpace(u)
		if u == "" || u == keep {
			continue
		}
		if _, ok := stillHeld[u]; ok {
			continue
		}
		out = append(out, u)
	}
	return out
}
