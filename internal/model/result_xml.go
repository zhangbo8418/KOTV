package model

import (
	"encoding/xml"
	"strings"
)

// rssXML 点播 Result/Vod/Class 的 XML 结构。
type rssXML struct {
	XMLName xml.Name   `xml:"rss"`
	Class   rssClass   `xml:"class"`
	List    rssList    `xml:"list"`
}

type rssClass struct {
	Ty []rssTy `xml:"ty"`
}

type rssTy struct {
	ID   string `xml:"id,attr"`
	Name string `xml:",chardata"`
}

type rssList struct {
	Video []rssVideo `xml:"video"`
}

type rssVideo struct {
	ID       string `xml:"id"`
	Name     string `xml:"name"`
	Type     string `xml:"type"`
	Pic      string `xml:"pic"`
	Note     string `xml:"note"`
	Year     string `xml:"year"`
	Area     string `xml:"area"`
	Director string `xml:"director"`
	Actor    string `xml:"actor"`
	Des      string `xml:"des"`
	DL       rssDL  `xml:"dl"`
}

type rssDL struct {
	DD []rssDD `xml:"dd"`
}

type rssDD struct {
	Flag string `xml:"flag,attr"`
	URLs string `xml:",chardata"`
}

// FromXML 解析 type=0 CMS XML 响应。
func FromXML(raw string) (Result, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return Result{Success: true}, nil
	}
	var rss rssXML
	if err := xml.Unmarshal([]byte(raw), &rss); err != nil {
		return Result{Success: false}, err
	}
	result := Result{Success: true}
	for _, ty := range rss.Class.Ty {
		result.Types = append(result.Types, Type{
			TypeID:   FlexString(strings.TrimSpace(ty.ID)),
			TypeName: strings.TrimSpace(ty.Name),
		})
	}
	for _, v := range rss.List.Video {
		vod := Vod{
			VodID:       FlexString(strings.TrimSpace(v.ID)),
			VodName:     strings.TrimSpace(v.Name),
			TypeName:    strings.TrimSpace(v.Type),
			VodPic:      strings.TrimSpace(v.Pic),
			VodRemarks:  strings.TrimSpace(v.Note),
			VodYear:     FlexString(strings.TrimSpace(v.Year)),
			VodArea:     strings.TrimSpace(v.Area),
			VodDirector: strings.TrimSpace(v.Director),
			VodActor:    strings.TrimSpace(v.Actor),
			VodContent:  strings.TrimSpace(v.Des),
		}
		var fromParts, urlParts []string
		for _, dd := range v.DL.DD {
			flag := strings.TrimSpace(dd.Flag)
			urls := strings.TrimSpace(dd.URLs)
			if flag == "" && urls == "" {
				continue
			}
			fromParts = append(fromParts, flag)
			urlParts = append(urlParts, urls)
			f := CreateFlag(flag)
			f.URLs = urls
			f.CreateEpisode(urls)
			vod.VodFlags = append(vod.VodFlags, f)
		}
		if len(fromParts) > 0 {
			vod.VodPlayFrom = strings.Join(fromParts, "$$$")
			vod.VodPlayURL = strings.Join(urlParts, "$$$")
		}
		if len(vod.VodFlags) > 0 {
			vod.SetCurrentFlag(0)
		}
		result.List = append(result.List, vod)
	}
	return result, nil
}

// FromType type==0 → XML，否则 JSON。
func FromType(typeID int, raw string) (Result, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" || raw == "{}" {
		return Result{Success: true}, nil
	}
	if typeID == 0 {
		return FromXML(raw)
	}
	result, err := DecodeResultJSON(raw)
	if err != nil {
		// 解析失败返回空结果而非错误，
		// 避免「脏 JSON」把整页打成失败态（此时仍显示空列表）。
		return Result{Success: true}, nil
	}
	result.Success = true
	return result, nil
}
