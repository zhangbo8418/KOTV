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

// mergeFilterDefaults ：对齐 TV FolderFragment：仅当 filter.init 非空时写入 extend。
// 不得回退到首个 value——AppDrama 等源无 init、首项常为具体标签（古装/2026…），
// 误填后 category 被过度收窄，整页「暂无内容」（TV 则空 extend 正常出片）。
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
