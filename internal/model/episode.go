package model

import "strings"

// Episode 剧集。
type Episode struct {
	Name      string `json:"name"`
	Desc      string `json:"desc"`
	URL       string `json:"url"`
	Number    int    `json:"-"`
	Activated bool   `json:"-"`
}

func CreateEpisode(name, url string) Episode {
	if s2tEpisode != nil {
		name = s2tEpisode(name)
	}
	return Episode{
		Name:   name,
		URL:    url,
		Number: GetDigit(name),
	}
}

// SetEpisodeS2T Episode.trans：由 spider 注册。
var s2tEpisode func(string) string

func SetEpisodeS2T(fn func(string) string) {
	s2tEpisode = fn
}

func (e Episode) Rule1(name string) bool {
	return strings.EqualFold(e.Name, name)
}

func (e Episode) Rule2(number int) bool {
	return e.Number == number && number != -1
}

func (e Episode) Rule3(name string) bool {
	return strings.Contains(strings.ToLower(e.Name), strings.ToLower(name))
}
