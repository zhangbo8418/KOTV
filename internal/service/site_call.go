package service

import (
	"encoding/base64"
	"strings"
	"unicode/utf8"

	"github.com/bobo/KOTV/internal/model"
	"github.com/bobo/KOTV/internal/util"
)

// siteAC type 0 → videolist，其余 → detail。
func siteAC(typeID int) string {
	if typeID == 0 {
		return "videolist"
	}
	return "detail"
}

// base64URLSafe URL-safe Base64（带 padding）。
func base64URLSafe(s string) string {
	return base64.URLEncoding.EncodeToString([]byte(s))
}

// siteCall 有 ext 时附加 extend（可为 http URL，不在此下载）；≤1000 字符 GET query，>1000 POST form。
func siteCall(site model.Site, params map[string]string) (string, error) {
	if params == nil {
		params = map[string]string{}
	}
	ext := strings.TrimSpace(site.Ext.String())
	if ext != "" {
		params["extend"] = ext
	}
	headers := map[string]string(site.Header)
	if utf8.RuneCountInString(ext) > 1000 {
		return util.HTTPPostFormInsecure(site.API, headers, params)
	}
	return util.HTTPGetParamsInsecure(site.API, headers, params)
}

// fetchExt Site.fetchExt：ext 以 http 开头则先下载正文写回。
func fetchExt(site model.Site) (model.Site, error) {
	ext := strings.TrimSpace(site.Ext.String())
	if !strings.HasPrefix(ext, "http") {
		return site, nil
	}
	body, err := util.HTTPGetParamsInsecure(ext, nil, nil)
	if err != nil || strings.TrimSpace(body) == "" {
		// OkHttp.string 异常→空串，不改 ext、不抛错。
		return site, nil
	}
	site.Ext = model.FlexString(strings.TrimSpace(body))
	return site, nil
}
