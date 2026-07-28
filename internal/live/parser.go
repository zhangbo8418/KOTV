package live

import (
	"encoding/json"
	"regexp"
	"strconv"
	"strings"

	"github.com/bobo/KOTV/internal/model"
)

var m3uHeaderRe = regexp.MustCompile(`(?m)^#EXTM3U`)

// Parse 解析直播源文本（JSON / M3U / TXT）。
func Parse(live *model.Live, text string) {
	if len(live.Groups) > 0 {
		return
	}
	normalized := strings.TrimSpace(text)
	switch {
	case strings.HasPrefix(normalized, "["):
		parseJSON(live, normalized)
	case isM3U(normalized):
		parseM3U(live, normalized)
	default:
		parseTXT(live, normalized)
	}
	apply(live)
}

func isM3U(text string) bool {
	if strings.Contains(text, "#genre#") && !m3uHeaderRe.MatchString(text) {
		return false
	}
	return m3uHeaderRe.MatchString(text)
}

func parseJSON(live *model.Live, text string) {
	var dtos []struct {
		Name    string `json:"name"`
		Channel []struct {
			Name string   `json:"name"`
			Logo string   `json:"logo"`
			URL  []string `json:"url"`
			URLs []string `json:"urls"`
		} `json:"channel"`
	}
	if err := json.Unmarshal([]byte(text), &dtos); err != nil {
		return
	}
	for _, dto := range dtos {
		g := live.FindGroup(dto.Name)
		for _, ch := range dto.Channel {
			c := g.FindChannel(ch.Name)
			c.Logo = ch.Logo
			urls := ch.URL
			if len(urls) == 0 {
				urls = ch.URLs
			}
			c.URLs = append(c.URLs, urls...)
		}
	}
}

func parseM3U(live *model.Live, text string) {
	var currentGroup *model.LiveGroup
	var currentChannel *model.LiveChannel
	globalCatchup := model.Catchup{}
	setting := &lineSetting{}

	text = strings.ReplaceAll(strings.ReplaceAll(text, "\r\n", "\n"), "\r", "")
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if setting.matches(line) {
			setting.apply(line)
			continue
		}
		switch {
		case strings.HasPrefix(line, "#EXTM3U"):
			globalCatchup = readCatchup(line, globalCatchup)
			if live.EPG == "" {
				if m := attrRe("url-tvg").FindStringSubmatch(line); len(m) > 1 {
					live.EPG = m[1]
				}
				if m := attrRe("tvg-url").FindStringSubmatch(line); len(m) > 1 {
					live.EPG = m[1]
				}
			}
			live.Catchup = model.CatchupDecide(readCatchup(line, model.Catchup{}), globalCatchup)
		case strings.HasPrefix(line, "#EXTINF:"):
			group := "默认"
			if m := attrRe("group-title").FindStringSubmatch(line); len(m) > 1 {
				group = m[1]
			}
			name := line
			if i := strings.LastIndex(line, ","); i >= 0 {
				name = strings.TrimSpace(line[i+1:])
			}
			currentGroup = live.FindGroup(group)
			currentChannel = currentGroup.FindChannel(name)
			if m := attrRe("tvg-logo").FindStringSubmatch(line); len(m) > 1 {
				currentChannel.Logo = m[1]
			}
			if m := attrRe("tvg-id").FindStringSubmatch(line); len(m) > 1 {
				currentChannel.TvgID = m[1]
			}
			if m := attrRe("tvg-name").FindStringSubmatch(line); len(m) > 1 {
				currentChannel.TvgName = m[1]
			}
			if m := attrRe("tvg-chno").FindStringSubmatch(line); len(m) > 1 {
				currentChannel.Number = m[1]
			}
			if m := regexp.MustCompile(`(?i)http-user-agent="([^"]*)"`).FindStringSubmatch(line); len(m) > 1 && m[1] != "" {
				currentChannel.UA = m[1]
			}
			cp := model.CatchupDecide(readCatchup(line, model.Catchup{}), globalCatchup)
			currentChannel.Catchup = &cp
		case !strings.HasPrefix(line, "#") && strings.Contains(line, "://"):
			parts := strings.SplitN(line, "|", 2)
			streamURL := strings.TrimSpace(parts[0])
			channel := currentChannel
			if channel == nil {
				if currentGroup == nil {
					currentGroup = live.FindGroup("默认")
				}
				channel = currentGroup.FindChannel("未命名")
				currentChannel = channel
			}
			channel.URLs = append(channel.URLs, streamURL)
			if len(parts) > 1 {
				setting.applyPipeHeaders(parts[1])
			}
			setting.copyTo(channel)
			setting.clear()
		}
	}

	filtered := make([]model.LiveGroup, 0, len(live.Groups))
	for _, g := range live.Groups {
		if len(g.Channels) > 0 {
			filtered = append(filtered, g)
		}
	}
	live.Groups = filtered
	if !globalCatchup.IsEmpty() {
		live.Catchup = globalCatchup
	}
}

func parseTXT(live *model.Live, text string) {
	var currentGroup *model.LiveGroup
	setting := &lineSetting{}
	text = strings.ReplaceAll(strings.ReplaceAll(text, "\r\n", "\n"), "\r", "")
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if setting.matches(line) {
			setting.apply(line)
		}
		if strings.Contains(line, "#genre#") {
			setting.clear()
			name := strings.TrimSpace(strings.SplitN(line, ",", 2)[0])
			currentGroup = live.FindGroup(name)
			continue
		}
		split := strings.SplitN(line, ",", 2)
		if len(split) == 2 && strings.Contains(split[1], "://") {
			if currentGroup == nil {
				currentGroup = live.FindGroup("默认")
			}
			channel := currentGroup.FindChannel(strings.TrimSpace(split[0]))
			for _, urlPart := range strings.Split(split[1], "#") {
				parts := strings.SplitN(urlPart, "|", 2)
				u := strings.TrimSpace(parts[0])
				if strings.Contains(u, "://") {
					if len(parts) > 1 {
						setting.applyPipeHeaders(parts[1])
					}
					channel.URLs = append(channel.URLs, u)
					setting.copyTo(channel)
				}
			}
		}
	}
}

func apply(live *model.Live) {
	number := 0
	for gi := range live.Groups {
		for ci := range live.Groups[gi].Channels {
			ch := &live.Groups[gi].Channels[ci]
			if ch.Number == "" {
				number++
				ch.Number = itoa(number)
			}
			ch.ApplyLive(live)
		}
	}
}

func attrRe(name string) *regexp.Regexp {
	return regexp.MustCompile(name + `="([^"]*)"`)
}

func readCatchup(line string, fallback model.Catchup) model.Catchup {
	attr := func(name string) string {
		m := attrRe(name).FindStringSubmatch(line)
		if len(m) > 1 {
			return m[1]
		}
		return ""
	}
	item := model.Catchup{
		Type:    attr("catchup"),
		Source:  attr("catchup-source"),
		Replace: attr("catchup-replace"),
	}
	return model.CatchupDecide(item, fallback)
}

type lineSetting struct {
	ua, referer, origin string
	parse               int
	format              string
	header              map[string]string
	drmKey, drmType     string
	drmHeader           map[string]string
	forceKey            bool
}

func (s *lineSetting) matches(line string) bool {
	return strings.HasPrefix(line, "ua") || strings.HasPrefix(line, "parse") ||
		strings.HasPrefix(line, "referer") || strings.HasPrefix(line, "origin") ||
		strings.HasPrefix(line, "header") || strings.HasPrefix(line, "format") ||
		strings.HasPrefix(line, "forceKey") ||
		strings.HasPrefix(line, "#EXTHTTP:") ||
		strings.HasPrefix(line, "#EXTVLCOPT:") || strings.HasPrefix(line, "#KODIPROP:")
}

func (s *lineSetting) apply(line string) {
	if s.header == nil {
		s.header = make(map[string]string)
	}
	if s.drmHeader == nil {
		s.drmHeader = make(map[string]string)
	}
	lower := strings.ToLower(line)
	switch {
	case strings.HasPrefix(lower, "ua="):
		s.ua = strings.TrimSpace(line[3:])
	case strings.HasPrefix(lower, "referer="):
		s.referer = strings.TrimSpace(line[len("referer="):])
	case strings.HasPrefix(lower, "origin="):
		s.origin = strings.TrimSpace(line[len("origin="):])
	case strings.HasPrefix(lower, "parse="):
		if n, err := strconv.Atoi(strings.TrimSpace(line[len("parse="):])); err == nil {
			s.parse = n
		}
	case strings.HasPrefix(lower, "format="):
		s.format = normalizeManifest(strings.TrimSpace(line[len("format="):]))
	case strings.HasPrefix(lower, "forcekey="):
		s.forceKey = strings.EqualFold(strings.TrimSpace(line[len("forceKey="):]), "true")
	case strings.HasPrefix(line, "#EXTVLCOPT:http-user-agent="):
		s.ua = strings.TrimPrefix(line, "#EXTVLCOPT:http-user-agent=")
	case strings.HasPrefix(line, "#EXTVLCOPT:http-referrer="):
		s.referer = strings.TrimPrefix(line, "#EXTVLCOPT:http-referrer=")
	case strings.HasPrefix(line, "#EXTVLCOPT:http-origin="):
		s.origin = strings.TrimPrefix(line, "#EXTVLCOPT:http-origin=")
	case strings.HasPrefix(line, "#EXTHTTP:"):
		s.applyPipeHeaders(strings.TrimPrefix(line, "#EXTHTTP:"))
	case strings.HasPrefix(line, "#KODIPROP:"):
		s.applyKodiProp(line)
	case strings.HasPrefix(lower, "header="):
		s.applyPipeHeaders(strings.TrimSpace(line[len("header="):]))
	}
}

func (s *lineSetting) applyKodiProp(line string) {
	body := strings.TrimPrefix(line, "#KODIPROP:")
	lower := strings.ToLower(body)
	switch {
	case strings.Contains(lower, "license_key="):
		s.setDrmKey(afterEq(body, "license_key="))
	case strings.Contains(lower, "license_type="):
		s.drmType = strings.TrimSpace(afterEq(body, "license_type="))
	case strings.Contains(lower, "drm_legacy="):
		legacy := strings.TrimSpace(afterEq(body, "drm_legacy="))
		parts := strings.SplitN(legacy, "|", 2)
		if len(parts) >= 1 {
			s.drmType = strings.TrimSpace(parts[0])
		}
		if len(parts) >= 2 {
			s.setDrmKey(strings.TrimSpace(parts[1]))
		}
	case strings.Contains(lower, "manifest_type="):
		s.format = normalizeManifest(strings.TrimSpace(afterEq(body, "manifest_type=")))
	case strings.Contains(lower, "stream_headers=") || strings.Contains(lower, "common_headers="):
		raw := body
		if i := strings.Index(lower, "headers="); i >= 0 {
			raw = body[i+len("headers="):]
		}
		s.applyAmpHeaders(s.header, raw)
	}
}

func (s *lineSetting) setDrmKey(key string) {
	key = strings.TrimSpace(key)
	if key == "" {
		return
	}
	if strings.HasPrefix(key, "http://") || strings.HasPrefix(key, "https://") {
		parts := strings.SplitN(key, "|", 2)
		s.drmKey = strings.TrimSpace(parts[0])
		if len(parts) > 1 {
			s.applyAmpHeaders(s.drmHeader, parts[1])
		}
		return
	}
	s.drmKey = model.NormalizeClearKey(key)
}

func (s *lineSetting) applyAmpHeaders(dst map[string]string, raw string) {
	if dst == nil {
		return
	}
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return
	}
	if strings.Contains(raw, "|") && !strings.Contains(raw, "&") {
		for _, part := range strings.Split(raw, "|") {
			s.applyAmpHeaders(dst, part)
		}
		return
	}
	for _, param := range strings.Split(raw, "&") {
		if !strings.Contains(param, "=") {
			continue
		}
		a := strings.SplitN(param, "=", 2)
		k := strings.Trim(strings.TrimSpace(a[0]), `"`)
		v := strings.Trim(strings.TrimSpace(a[1]), `"`)
		switch k {
		case "drmScheme":
			s.drmType = v
		case "drmLicense":
			s.setDrmKey(v)
		default:
			dst[k] = v
		}
	}
}

func (s *lineSetting) applyPipeHeaders(raw string) {
	if s.header == nil {
		s.header = make(map[string]string)
	}
	raw = strings.TrimSpace(raw)
	if strings.HasPrefix(raw, "{") {
		_ = json.Unmarshal([]byte(raw), &s.header)
		return
	}
	for _, part := range strings.Split(raw, "&") {
		kv := strings.SplitN(part, "=", 2)
		if len(kv) == 2 {
			s.header[kv[0]] = kv[1]
		}
	}
}

func (s *lineSetting) copyTo(ch *model.LiveChannel) {
	if s.ua != "" {
		ch.UA = s.ua
	}
	if s.referer != "" {
		ch.Referer = s.referer
	}
	if s.origin != "" {
		ch.Origin = s.origin
	}
	if s.parse != 0 {
		ch.Parse = s.parse
	}
	if s.format != "" {
		ch.Format = s.format
	}
	if len(s.header) > 0 {
		if ch.Header == nil {
			ch.Header = make(map[string]string)
		}
		for k, v := range s.header {
			ch.Header[k] = v
		}
	}
	if s.drmKey != "" && s.drmType != "" {
		hdr := map[string]string{}
		for k, v := range s.drmHeader {
			hdr[k] = v
		}
		ch.Drm = &model.Drm{
			Key:      s.drmKey,
			Type:     s.drmType,
			ForceKey: s.forceKey,
			Header:   hdr,
		}
	}
}

func (s *lineSetting) clear() {
	s.ua, s.referer, s.origin = "", "", ""
	s.parse = 0
	s.format = ""
	s.header = make(map[string]string)
	s.drmKey, s.drmType = "", ""
	s.drmHeader = make(map[string]string)
	s.forceKey = false
}

func afterEq(s, key string) string {
	lower := strings.ToLower(s)
	k := strings.ToLower(key)
	i := strings.Index(lower, k)
	if i < 0 {
		return ""
	}
	return s[i+len(key):]
}

func normalizeManifest(f string) string {
	f = strings.ToLower(strings.TrimSpace(f))
	switch f {
	case "mpd", "dash":
		return "application/dash+xml"
	case "hls", "m3u8":
		return "application/x-mpegURL"
	default:
		return f
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [12]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}
