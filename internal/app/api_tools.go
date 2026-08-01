package app

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/bobo/KOTV/internal/backup"
	"github.com/bobo/KOTV/internal/cacheclean"
	"github.com/bobo/KOTV/internal/cast"
	"github.com/bobo/KOTV/internal/database"
	"github.com/bobo/KOTV/internal/player/embed"
	"github.com/bobo/KOTV/internal/playproxy"
	"github.com/bobo/KOTV/internal/settings"
	"github.com/bobo/KOTV/internal/update"
)

const defaultSyncPort = "9978"

// APITools Flutter 设置页工具动作（备份/爬虫/更新/同步/投屏等）。
func (a *App) APITools(action string, params map[string]any) (map[string]any, error) {
	action = strings.TrimSpace(strings.ToLower(action))
	if params == nil {
		params = map[string]any{}
	}
	switch action {
	case "checkupdate":
		return a.toolCheckUpdate()
	case "checkspider":
		return a.toolCheckSpider()
	case "resetpair":
		code := settings.ResetSyncPairCode()
		_ = settings.Save()
		return map[string]any{"ok": true, "pairCode": code, "message": "新配对码: " + code}, nil
	case "syncsend":
		return a.toolSyncSend(strParam(params, "host"), strParam(params, "pair"), strParam(params, "type"))
	case "backupexport":
		return a.toolBackupExport(strParam(params, "path"))
	case "backupimport":
		return a.toolBackupImport(strParam(params, "path"))
	case "castdiscover":
		return a.toolCastDiscover()
	case "cast":
		idx := intParam(params, "index", -1)
		return a.toolCast(idx)
	case "clearcache":
		return a.toolClearCache(params)
	default:
		return nil, fmt.Errorf("unknown action: %s", action)
	}
}

func (a *App) toolClearCache(params map[string]any) (map[string]any, error) {
	opt := cacheclean.Options{
		Script: boolParam(params, "script", true),
		Jar:    boolParam(params, "jar", true),
		Magnet: boolParam(params, "magnet", true),
		Logs:   boolParam(params, "logs", true),
		Other:  boolParam(params, "other", true),
	}
	res := cacheclean.Run(opt)
	msg := fmt.Sprintf("已清理 %s", res.FreedHuman)
	if len(res.Cleared) > 0 {
		msg += "（" + strings.Join(res.Cleared, "、") + "）"
	}
	if len(res.Errors) > 0 {
		msg += "；部分失败: " + strings.Join(res.Errors, "; ")
	}
	out := map[string]any{
		"ok":         true,
		"message":    msg,
		"freedBytes": res.FreedBytes,
		"freedHuman": res.FreedHuman,
		"cleared":    res.Cleared,
		"details":    res.Details,
	}
	if len(res.Errors) > 0 {
		out["errors"] = res.Errors
	}
	return out, nil
}

func boolParam(m map[string]any, key string, def bool) bool {
	v, ok := m[key]
	if !ok || v == nil {
		return def
	}
	switch t := v.(type) {
	case bool:
		return t
	case string:
		s := strings.TrimSpace(strings.ToLower(t))
		if s == "0" || s == "false" || s == "no" || s == "off" {
			return false
		}
		if s == "1" || s == "true" || s == "yes" || s == "on" {
			return true
		}
	case float64:
		return t != 0
	case int:
		return t != 0
	}
	return def
}

func (a *App) toolCheckUpdate() (map[string]any, error) {
	info, err := update.Check(settings.Get(settings.UpdateURL))
	if err != nil {
		return nil, err
	}
	out := map[string]any{
		"ok":      true,
		"current": update.CurrentVersion,
		"newer":   false,
	}
	if info == nil {
		out["message"] = "已是最新版本 " + update.CurrentVersion
		return out, nil
	}
	out["newer"] = true
	out["version"] = info.Version
	out["notes"] = info.Notes
	out["message"] = "发现新版本 " + info.Version
	return out, nil
}

func (a *App) toolCheckSpider() (map[string]any, error) {
	if localCrawlerDisabled() {
		return nil, fmt.Errorf("请先连接可用后端服务")
	}
	if !a.Ready {
		return nil, fmt.Errorf("配置未就绪")
	}
	sites := a.Config.Sites()
	ok, fail := 0, 0
	results := make([]map[string]any, 0, len(sites))
	for _, site := range sites {
		sp := a.Config.Spider(site)
		_, err := sp.HomeContent(true)
		msg := "ok"
		st := 1
		if err != nil {
			st = 0
			msg = err.Error()
			fail++
		} else {
			ok++
		}
		_ = a.DB.UpsertSpiderStatus(database.SpiderStatus{
			SiteKey: site.Key,
			Status:  st,
			Message: msg,
		})
		results = append(results, map[string]any{
			"key":     site.Key,
			"name":    site.Name,
			"ok":      st == 1,
			"message": msg,
		})
	}
	return map[string]any{
		"ok":      true,
		"success": ok,
		"fail":    fail,
		"results": results,
		"message": fmt.Sprintf("检测完成: 成功 %d / 失败 %d", ok, fail),
	}, nil
}

func (a *App) toolSyncSend(host, pair, syncType string) (map[string]any, error) {
	host = strings.TrimSpace(host)
	pair = strings.TrimSpace(pair)
	syncType = strings.TrimSpace(syncType)
	if host == "" {
		return nil, fmt.Errorf("IP 不能为空")
	}
	if pair == "" {
		return nil, fmt.Errorf("配对码不能为空")
	}
	if syncType != "history" && syncType != "keep" {
		return nil, fmt.Errorf("无效同步类型")
	}
	body, err := exportSyncPayload(a.DB, syncType)
	if err != nil {
		return nil, err
	}
	if err := sendSyncData(host, pair, syncType, 1, body); err != nil {
		return nil, err
	}
	label := "历史"
	if syncType == "keep" {
		label = "收藏"
	}
	return map[string]any{"ok": true, "message": "已发送" + label}, nil
}

func (a *App) toolBackupExport(path string) (map[string]any, error) {
	path = strings.TrimSpace(path)
	if path == "" {
		return nil, fmt.Errorf("请指定备份路径")
	}
	data, err := backup.Export(a.DB)
	if err != nil {
		return nil, err
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		return nil, err
	}
	return map[string]any{"ok": true, "path": path, "message": "备份已导出"}, nil
}

func (a *App) toolBackupImport(path string) (map[string]any, error) {
	path = strings.TrimSpace(path)
	if path == "" {
		return nil, fmt.Errorf("请指定备份文件")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if len(data) > 32<<20 {
		return nil, fmt.Errorf("备份文件过大")
	}
	if err := backup.Import(a.DB, data); err != nil {
		return nil, err
	}
	a.SyncDLNARenderer()
	return map[string]any{"ok": true, "message": "备份已恢复"}, nil
}

func (a *App) toolCastDiscover() (map[string]any, error) {
	// 允许先搜设备；真正投送时再校验 MediaURL
	devs, err := cast.Discover(4 * time.Second)
	if err != nil {
		return nil, err
	}
	a.castMu.Lock()
	a.castDevs = devs
	a.castMu.Unlock()
	list := make([]map[string]any, 0, len(devs))
	for i, d := range devs {
		list = append(list, map[string]any{
			"index":    i,
			"name":     d.Name,
			"protocol": string(d.Protocol),
			"detail":   d.Detail,
			"label":    d.Label(),
		})
	}
	return map[string]any{
		"ok":      true,
		"devices": list,
		"count":   len(list),
		"message": fmt.Sprintf("发现 %d 台设备", len(list)),
	}, nil
}

func (a *App) toolCast(index int) (map[string]any, error) {
	a.castMu.Lock()
	devs := a.castDevs
	a.castMu.Unlock()
	if index < 0 || index >= len(devs) {
		return nil, fmt.Errorf("请先搜索设备并选择有效项")
	}
	mediaURL := a.MediaURL()
	if mediaURL == "" {
		return nil, fmt.Errorf("请先播放内容再投屏")
	}
	posMs := int64(0)
	if eng := embed.Active(); eng != nil {
		posMs = eng.PositionMs()
	}
	castURL, headers := playproxy.Resolve(mediaURL)
	if castURL == "" {
		castURL = mediaURL
	}
	used, err := cast.CastWith(devs[index], castURL, a.MediaTitle(), headers, posMs)
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"ok":       true,
		"name":     used.Name,
		"protocol": string(used.Protocol),
		"label":    used.Label(),
		"message":  "已投屏到 " + used.Label(),
	}, nil
}

func exportSyncPayload(db *database.DB, syncType string) ([]byte, error) {
	switch syncType {
	case "history":
		items, err := db.ListAllHistory()
		if err != nil {
			return nil, err
		}
		return json.Marshal(items)
	case "keep":
		items, err := db.ListAllKeep(database.KeepTypeVod)
		if err != nil {
			return nil, err
		}
		return json.Marshal(items)
	default:
		return nil, fmt.Errorf("无效同步类型")
	}
}

func sendSyncData(host, pair, syncType string, mode int, body []byte) error {
	host = strings.TrimSpace(host)
	pair = strings.TrimSpace(pair)
	h, p, err := net.SplitHostPort(host)
	if err != nil {
		h = host
		p = defaultSyncPort
	}
	addr := net.JoinHostPort(h, p)
	url := fmt.Sprintf("http://%s/action?do=sync&type=%s&mode=%d&pair=%s", addr, syncType, mode, pair)
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		if len(b) > 0 {
			return fmt.Errorf("%s", strings.TrimSpace(string(b)))
		}
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return nil
}

func strParam(m map[string]any, key string) string {
	v, ok := m[key]
	if !ok || v == nil {
		return ""
	}
	return strings.TrimSpace(fmt.Sprint(v))
}

func intParam(m map[string]any, key string, def int) int {
	v, ok := m[key]
	if !ok || v == nil {
		return def
	}
	switch t := v.(type) {
	case float64:
		return int(t)
	case int:
		return t
	case json.Number:
		n, _ := t.Int64()
		return int(n)
	default:
		var n int
		_, _ = fmt.Sscanf(fmt.Sprint(v), "%d", &n)
		return n
	}
}
