package source

import (
	"context"
	"regexp"
	"strings"

	"github.com/bobo/KOTV/internal/model"
)

var playlistURLRe = regexp.MustCompile(`(?i)(youtube\.com|youtu\.be).*list=`)

// MatchPlaylist 是否为须展开为多集的 YouTube 播放列表地址。
func MatchPlaylist(raw string) bool {
	return playlistURLRe.MatchString(strings.TrimSpace(raw))
}

// NeedsPlaylistExpand 详情里是否含 YouTube 播放列表。
func NeedsPlaylistExpand(vod *model.Vod) bool {
	if vod == nil {
		return false
	}
	for _, f := range vod.VodFlags {
		for _, ep := range f.Episodes {
			if MatchPlaylist(ep.URL) {
				return true
			}
		}
	}
	return false
}

// ParseVodPlaylists 把播放列表剧集展开为单集 watch URL；失败时保留原链。
func ParseVodPlaylists(ctx context.Context, vod *model.Vod) {
	if vod == nil || len(vod.VodFlags) == 0 {
		return
	}
	if ctx == nil {
		ctx = context.Background()
	}
	for i := range vod.VodFlags {
		parsePlaylistFlag(ctx, &vod.VodFlags[i])
	}
}

func parsePlaylistFlag(ctx context.Context, f *model.Flag) {
	if f == nil {
		return
	}
	var kept []model.Episode
	var expanded []model.Episode
	for _, ep := range f.Episodes {
		if ctx.Err() != nil {
			kept = append(kept, ep)
			continue
		}
		if !MatchPlaylist(ep.URL) {
			kept = append(kept, ep)
			continue
		}
		eps, err := fetchPlaylistPlatform(ctx, ep.URL)
		if err != nil || len(eps) == 0 {
			kept = append(kept, ep)
			continue
		}
		expanded = append(expanded, eps...)
	}
	if len(expanded) == 0 {
		return
	}
	f.Episodes = append(kept, expanded...)
}
