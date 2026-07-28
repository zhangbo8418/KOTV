package service

import (
	"encoding/base64"
	"strings"

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

// siteCall 有 ext 时附加 extend；≤1000 GET query，>1000 POST form。
func siteCall(site model.Site, params map[string]string) (string, error) {
	if params == nil {
		params = map[string]string{}
	}
	ext := strings.TrimSpace(site.Ext.String())
	if ext != "" {
		params["extend"] = ext
	}
	headers := map[string]string(site.Header)
	if len(ext) > 1000 {
		return util.HTTPPostForm(site.API, headers, params)
	}
	return util.HTTPGetParams(site.API, headers, params)
}

// fetchExt Site.fetchExt：ext 以 http 开头则先下载正文写回。
func fetchExt(site model.Site) (model.Site, error) {
	ext := strings.TrimSpace(site.Ext.String())
	if !strings.HasPrefix(ext, "http://") && !strings.HasPrefix(ext, "https://") {
		return site, nil
	}
	body, err := util.HTTPGet(ext, map[string]string(site.Header))
	if err != nil {
		return site, err
	}
	body = strings.TrimSpace(body)
	if body != "" {
		site.Ext = model.FlexString(body)
	}
	return site, nil
}
