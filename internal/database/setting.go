package database

import (
	"database/sql"
	"strings"
)

// SettingKV 批量覆盖写入用的 id/value 对。
type SettingKV struct {
	ID    string
	Value string
}

// GetSetting 读取 owner+id；无行返回 ok=false。
func (db *DB) GetSetting(owner, id string) (value string, ok bool, err error) {
	if db == nil || db.conn == nil {
		return "", false, nil
	}
	id = strings.TrimSpace(id)
	if id == "" {
		return "", false, nil
	}
	var v string
	err = db.conn.QueryRow(
		`SELECT value FROM setting WHERE owner = ? AND id = ?`, owner, id,
	).Scan(&v)
	if err == sql.ErrNoRows {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return v, true, nil
}

// SetSetting UPSERT 一条设置。
func (db *DB) SetSetting(owner, id, value string) error {
	if db == nil || db.conn == nil {
		return nil
	}
	id = strings.TrimSpace(id)
	if id == "" {
		return nil
	}
	_, err := db.conn.Exec(
		`INSERT INTO setting(owner, id, value) VALUES(?,?,?)
		 ON CONFLICT(owner, id) DO UPDATE SET value = excluded.value`,
		owner, id, value,
	)
	return err
}

// ListSettings 列出某 owner 全部设置。
func (db *DB) ListSettings(owner string) (map[string]string, error) {
	out := map[string]string{}
	if db == nil || db.conn == nil {
		return out, nil
	}
	rows, err := db.conn.Query(`SELECT id, value FROM setting WHERE owner = ?`, owner)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id, v string
		if err := rows.Scan(&id, &v); err != nil {
			return nil, err
		}
		out[id] = v
	}
	return out, rows.Err()
}

// DeleteSettingsOwner 删除某 owner 全部设置行（含 owner=''，供备份覆盖写入）。
func (db *DB) DeleteSettingsOwner(owner string) error {
	if db == nil || db.conn == nil {
		return nil
	}
	_, err := db.conn.Exec(`DELETE FROM setting WHERE owner = ?`, owner)
	return err
}

// ReplaceSettings 单事务清空 owner 后写入 [items]（覆盖语义）。
func (db *DB) ReplaceSettings(owner string, items []SettingKV) error {
	if db == nil || db.conn == nil {
		return nil
	}
	tx, err := db.conn.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM setting WHERE owner = ?`, owner); err != nil {
		return err
	}
	for _, it := range items {
		id := strings.TrimSpace(it.ID)
		if id == "" {
			continue
		}
		if _, err := tx.Exec(
			`INSERT INTO setting(owner, id, value) VALUES(?,?,?)`,
			owner, id, it.Value,
		); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// ClearKeep 清空某 owner 全部收藏（点播+直播）。
func (db *DB) ClearKeep(owner string) error {
	_, err := db.conn.Exec(`DELETE FROM keep WHERE owner = ?`, owner)
	return err
}
