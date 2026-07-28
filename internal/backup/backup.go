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
	Version  int               `json:"version"`
	Settings []settings.Entry  `json:"settings"`
	History  []database.History `json:"history"`
	Keep     []database.Keep   `json:"keep"`
}

// Export 导出 gzip 压缩的 JSON 备份。
func Export(db *database.DB) ([]byte, error) {
	hist, err := db.ListAllHistory()
	if err != nil {
		return nil, err
	}
	keep, err := db.ListAllKeep(database.KeepTypeVod)
	if err != nil {
		return nil, err
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

// Import 从 gzip JSON 恢复；事务写入 history/keep，再替换 settings。
func Import(db *database.DB, data []byte) error {
	raw, err := gunzip(data)
	if err != nil {
		return err
	}
	var payload Payload
	if err := json.Unmarshal(raw, &payload); err != nil {
		return fmt.Errorf("备份格式无效: %w", err)
	}
	if payload.Version > version {
		return fmt.Errorf("备份版本 %d 不受支持", payload.Version)
	}
	if err := db.ImportHistory(payload.History, 2); err != nil {
		return fmt.Errorf("恢复历史失败: %w", err)
	}
	if err := db.ImportKeep(payload.Keep, 2); err != nil {
		return fmt.Errorf("恢复收藏失败: %w", err)
	}
	if len(payload.Settings) > 0 {
		settings.ReplaceEntries(payload.Settings)
		if err := settings.Save(); err != nil {
			return fmt.Errorf("恢复设置失败: %w", err)
		}
	}
	return nil
}

func gunzip(data []byte) ([]byte, error) {
	gr, err := gzip.NewReader(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	defer gr.Close()
	return io.ReadAll(io.LimitReader(gr, 32<<20))
}
