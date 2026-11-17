package spider

import (
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
	"sync"

	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/util"
)

func init() {
	util.SetVodNetHooks(RewriteVodURLHost, InjectVodHeaders)
	util.SetHTTPAuthOwner(hostclient.RuntimeUserID)
}

// 点播配置 headers/hosts 的 Go 侧表（jar 仍走 bridge SetNetConfig）。
// 按 RuntimeUserID 分桶（空串=本机共享），避免多租户互相覆盖。
type vodHeaderRule struct {
	host    string
	headers map[string]string
}

var (
	vodNetMu       sync.RWMutex
	vodHdrByOwner  = map[string][]vodHeaderRule{}
	vodHostByOwner = map[string]map[string]string{} // owner -> pattern -> target hostname
)

func vodNetOwner() string {
	return hostclient.RuntimeUserID()
}

func setGoNetConfig(headersJSON, hostsJSON []byte) {
	rules := parseVodHeaderRules(headersJSON)
	hosts := parseVodHosts(hostsJSON)
	owner := vodNetOwner()
	vodNetMu.Lock()
	if len(rules) == 0 {
		delete(vodHdrByOwner, owner)
	} else {
		vodHdrByOwner[owner] = rules
	}
	if len(hosts) == 0 {
		delete(vodHostByOwner, owner)
	} else {
		vodHostByOwner[owner] = hosts
	}
	vodNetMu.Unlock()
	// 按 RuntimeUserID 分桶；换源只清当前租户。
	util.ClearHTTPAuth()
}

// clearGoNetConfigForUser 清远端用户的 Go 侧 headers/hosts 桶。
func clearGoNetConfigForUser(userID string) {
	userID = strings.TrimSpace(userID)
	if userID == "" {
		return
	}
	vodNetMu.Lock()
	delete(vodHdrByOwner, userID)
	delete(vodHostByOwner, userID)
	vodNetMu.Unlock()
}

// clearGoNetConfigForShared 清本机共享桶（owner 空串）。
func clearGoNetConfigForShared() {
	vodNetMu.Lock()
	delete(vodHdrByOwner, "")
	delete(vodHostByOwner, "")
	vodNetMu.Unlock()
}

func parseVodHeaderRules(raw []byte) []vodHeaderRule {
	trimmed := strings.TrimSpace(string(raw))
	if trimmed == "" || trimmed == "null" {
		return nil
	}
	var items []struct {
		Host   string          `json:"host"`
		Header json.RawMessage `json:"header"`
	}
	if err := json.Unmarshal(raw, &items); err != nil {
		return nil
	}
	out := make([]vodHeaderRule, 0, len(items))
	for _, it := range items {
		host := strings.TrimSpace(it.Host)
		if host == "" || len(it.Header) == 0 {
			continue
		}
		hdrs := map[string]string{}
		if err := json.Unmarshal(it.Header, &hdrs); err != nil || len(hdrs) == 0 {
			var any map[string]interface{}
			if json.Unmarshal(it.Header, &any) != nil {
				continue
			}
			for k, v := range any {
				hdrs[k] = fmt.Sprint(v)
			}
		}
		if len(hdrs) == 0 {
			continue
		}
		out = append(out, vodHeaderRule{host: host, headers: hdrs})
	}
	return out
}

func parseVodHosts(raw []byte) map[string]string {
	trimmed := strings.TrimSpace(string(raw))
	if trimmed == "" || trimmed == "null" {
		return nil
	}
	var list []string
	if err := json.Unmarshal(raw, &list); err != nil {
		return nil
	}
	out := map[string]string{}
	for _, line := range list {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}
		k := strings.TrimSpace(parts[0])
		v := strings.TrimSpace(parts[1])
		if k != "" && v != "" {
			out[k] = v
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// ResolveVodHost OkDns.get：精确命中或 ContainOrMatch 后返回映射主机名。
func ResolveVodHost(hostname string) string {
	hostname = strings.TrimSpace(hostname)
	if hostname == "" {
		return hostname
	}
	owner := vodNetOwner()
	vodNetMu.RLock()
	vodHostMap := vodHostByOwner[owner]
	defer vodNetMu.RUnlock()
	if len(vodHostMap) == 0 {
		return hostname
	}
	if t, ok := vodHostMap[hostname]; ok {
		return t
	}
	for pattern, target := range vodHostMap {
		if util.ContainOrMatch(hostname, pattern) {
			return target
		}
	}
	return hostname
}

// RewriteVodURLHost 按 hosts 表替换 URL hostname（再走系统 DNS）。
func RewriteVodURLHost(rawURL string) string {
	rawURL = strings.TrimSpace(rawURL)
	if rawURL == "" {
		return rawURL
	}
	u, err := url.Parse(rawURL)
	if err != nil || u.Host == "" {
		return rawURL
	}
	host := u.Hostname()
	mapped := ResolveVodHost(host)
	if mapped == host || mapped == "" {
		return rawURL
	}
	port := u.Port()
	if port != "" {
		u.Host = mapped + ":" + port
	} else {
		u.Host = mapped
	}
	return u.String()
}

// InjectVodHeaders ResponseInterceptor.check：按 host 匹配后写入（覆盖同名）。
func InjectVodHeaders(rawURL string, headers map[string]string) map[string]string {
	host := ""
	if u, err := url.Parse(strings.TrimSpace(rawURL)); err == nil {
		host = u.Hostname()
	}
	if host == "" {
		return headers
	}
	owner := vodNetOwner()
	vodNetMu.RLock()
	rules := vodHdrByOwner[owner]
	vodNetMu.RUnlock()
	if len(rules) == 0 {
		return headers
	}
	out := headers
	if out == nil {
		out = map[string]string{}
	} else {
		cp := make(map[string]string, len(out)+4)
		for k, v := range out {
			cp[k] = v
		}
		out = cp
	}
	for _, rule := range rules {
		if !util.ContainOrMatch(host, rule.host) {
			continue
		}
		for k, v := range rule.headers {
			out[k] = v
		}
	}
	return out
}
