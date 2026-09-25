package backup

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"

	"github.com/bobo/KOTV/internal/database"
	"github.com/bobo/KOTV/internal/settings"
)

const version = 1

// Payload 备份包内容。
type Payload struct {
	Version  int                 `json:"version"`
	Settings []settings.Entry    `json:"settings"`
	History  []database.History  `json:"history"`
	Keep     []database.Keep     `json:"keep"`
}

// ExportClient 用客户端传入的历史/收藏打包（不读引擎 DB 列表）。
func ExportClient(hist []database.History, keep []database.Keep) ([]byte, error) {
	if hist == nil {
		hist = []database.History{}
	}
	if keep == nil {
		keep = []database.Keep{}
	}
	payload := Payload{
		Version:  version,
		Settings: settings.ListEntries(),
		History:  hist,
		Keep:     keep,
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	gw := gzip.NewWriter(&buf)
	if _, err := gw.Write(raw); err != nil {
		return nil, err
	}
	if err := gw.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// Import 从 gzip JSON 恢复；写入引擎 DB 的 history/keep 与 settings，并返回 payload 供客户端落 SP。
func Import(db *database.DB, data []byte) (*Payload, error) {
	raw, err := gunzip(data)
	if err != nil {
		return nil, err
	}
	var payload Payload
	if err := json.Unmarshal(raw, &payload); err != nil {
		return nil, fmt.Errorf("备份格式无效: %w", err)
	}
	if payload.Version > version {
		return nil, fmt.Errorf("备份版本 %d 不受支持", payload.Version)
	}
	if err := db.ImportHistory(payload.History, 2); err != nil {
		return nil, fmt.Errorf("恢复历史失败: %w", err)
	}
	if err := db.ImportKeep(payload.Keep, 2); err != nil {
		return nil, fmt.Errorf("恢复收藏失败: %w", err)
	}
	if len(payload.Settings) > 0 {
		settings.ReplaceEntries(payload.Settings)
		if err := settings.Save(); err != nil {
			return nil, fmt.Errorf("恢复设置失败: %w", err)
		}
	}
	return &payload, nil
}

func gunzip(data []byte) ([]byte, error) {
	gr, err := gzip.NewReader(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	defer gr.Close()
	return io.ReadAll(io.LimitReader(gr, 32<<20))
}
