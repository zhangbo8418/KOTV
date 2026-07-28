package service

import (
	"strings"

	"github.com/bobo/KOTV/internal/model"
)

func copyStringMap(src map[string]string) map[string]string {
	if len(src) == 0 {
		return map[string]string{}
	}
	out := make(map[string]string, len(src))
	for k, v := range src {
		out[k] = v
	}
	return out
}

func filtersForHomeTid(home model.Result, tid string) []model.Filter {
	tid = strings.TrimSpace(tid)
	for _, typ := range home.Types {
		if typ.TypeID.String() == tid && len(typ.Filters) > 0 {
			return typ.Filters
		}
	}
	if fs, ok := home.Filters[tid]; ok && len(fs) > 0 {
		return fs
	}
	return nil
}

// mergeFilterDefaults ：把筛选项 init（或首个 value）写入 extend 缺省键。
func mergeFilterDefaults(extend map[string]string, filters []model.Filter) {
	if extend == nil || len(filters) == 0 {
		return
	}
	for _, f := range filters {
		key := strings.TrimSpace(f.Key)
		if key == "" || strings.TrimSpace(extend[key]) != "" {
			continue
		}
		if v := strings.TrimSpace(f.Init.String()); v != "" {
			extend[key] = v
			continue
		}
		if len(f.Value) > 0 {
			extend[key] = f.Value[0].V.String()
		}
	}
}

// FiltersForCategory 返回首页缓存里某分类的筛选项（含 filters 全局表 fallback）。
func (s *SiteService) FiltersForCategory(tid string) []model.Filter {
	s.mu.Lock()
	defer s.mu.Unlock()
	return filtersForHomeTid(s.HomeResult, tid)
}

// MergeCategoryExtend 返回带筛选项默认值的 extend（供分类请求与 UI 筛选条共用）。
func (s *SiteService) MergeCategoryExtend(tid string, extend map[string]string) map[string]string {
	out := copyStringMap(extend)
	s.mu.Lock()
	filters := filtersForHomeTid(s.HomeResult, tid)
	s.mu.Unlock()
	mergeFilterDefaults(out, filters)
	return out
}
