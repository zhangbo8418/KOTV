package service

import (
	"sort"
	"strings"

	"github.com/bobo/KOTV/internal/model"
)

func extendCacheKey(extend map[string]string) string {
	if len(extend) == 0 {
		return "-"
	}
	keys := make([]string, 0, len(extend))
	for k := range extend {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	for i, k := range keys {
		if i > 0 {
			b.WriteByte('&')
		}
		b.WriteString(k)
		b.WriteByte('=')
		b.WriteString(extend[k])
	}
	return b.String()
}

func categoryCacheKey(site model.Site, tid, pg string, extend map[string]string) string {
	return site.Key + "\x00" + tid + "\x00" + pg + "\x00" + extendCacheKey(extend)
}

func (s *SiteService) invalidateContentCache() {
	s.homeCacheSite = ""
	s.HomeResult = model.Result{}
	s.categoryCache = make(map[string]model.Result)
}

func (s *SiteService) getCategoryCache(site model.Site, tid, pg string, extend map[string]string) (model.Result, bool) {
	if s.categoryCache == nil {
		return model.Result{}, false
	}
	key := categoryCacheKey(site, tid, pg, extend)
	result, ok := s.categoryCache[key]
	return result, ok
}

func (s *SiteService) putCategoryCache(site model.Site, tid, pg string, extend map[string]string, result model.Result) {
	if s.categoryCache == nil {
		s.categoryCache = make(map[string]model.Result)
	}
	s.categoryCache[categoryCacheKey(site, tid, pg, extend)] = result
}
