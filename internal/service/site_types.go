package service

import (
	"strings"

	"github.com/bobo/KOTV/internal/model"
	"github.com/bobo/KOTV/internal/util"
)

// applyTypes 挂 filters，并按 categories 名称保序过滤。
func applyTypes(site model.Site, r *model.Result) {
	if r == nil {
		return
	}
	for i := range r.Types {
		tid := r.Types[i].TypeID.String()
		if fs, ok := r.Filters[tid]; ok {
			r.Types[i].Filters = fs
		}
	}
	if len(site.Categories) == 0 {
		return
	}
	byName := make(map[string]model.Type, len(r.Types))
	for _, t := range r.Types {
		byName[t.TypeName] = t
	}
	var ordered []model.Type
	for _, name := range site.Categories {
		if t, ok := byName[name]; ok {
			ordered = append(ordered, t)
		}
	}
	if len(ordered) > 0 {
		r.Types = ordered
	}
}

// fetchPic type≤2 且首条无图时，用 ac+ids 二次请求替换列表。
func fetchPic(site model.Site, r model.Result) (model.Result, error) {
	if site.TypeID() > 2 || len(r.List) == 0 || strings.TrimSpace(r.List[0].VodPic) != "" {
		return r, nil
	}
	var ids []string
	emptyCats := len(site.Categories) == 0
	for _, item := range r.List {
		if emptyCats || containsString(site.Categories, item.TypeName) {
			ids = append(ids, item.VodID.String())
		}
	}
	if len(ids) == 0 {
		r.List = nil
		return r, nil
	}
	params := map[string]string{
		"ac":  siteAC(site.TypeID()),
		"ids": strings.Join(ids, ","),
	}
	// fetchPic 走 OkHttp.newCall(..., params)，不附加 extend。
	body, err := util.HTTPGetParams(site.API, map[string]string(site.Header), params)
	if err != nil {
		return r, err
	}
	detail, err := model.FromType(site.TypeID(), body)
	if err != nil {
		return r, err
	}
	r.List = detail.List
	return r, nil
}

func containsString(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}
