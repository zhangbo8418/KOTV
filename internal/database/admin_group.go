package database

import (
	"database/sql"
	"fmt"
	"strings"
	"time"
)

const DefaultGroupID = "default"

// AuthGroup 用户分组。
type AuthGroup struct {
	ID        string
	Name      string
	Note      string
	Enabled   bool
	Sort      int
	CreatedAt time.Time
}

type GroupLive struct {
	ID      string
	GroupID string
	Name    string
	URL     string
	Sort    int
	Enabled bool
}

type GroupSetting struct {
	GroupID string
	Key     string
	Value   string
}

type AdminNotice struct {
	ID        string `json:"id"`
	Scope     string `json:"scope"` // all|group|user
	TargetID  string `json:"targetId"`
	Kind      string `json:"kind"` // banner|toast|dialog
	Title     string `json:"title"`
	Body      string `json:"body"`
	Link      string `json:"link"`
	Sticky    bool   `json:"sticky"`
	Priority  int    `json:"priority"`
	StartsAt  int64  `json:"startsAt"`
	EndsAt    int64  `json:"endsAt"`
	CreatedAt int64  `json:"createdAt"`
	CreatedBy string `json:"createdBy"`
}

type UsageEvent struct {
	At       int64
	UserID   string
	GroupID  string
	ClientID string
	Platform string
	Arch     string
	AppVer   string
	Protocol string
	IP       string
	Kind     string
	RefType  string
	RefID    string
	RefName  string
	OK       bool
	ErrCode  string
	Latency  int64
	MetaJSON string
}

func (db *DB) migrateAdminGroups() error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS auth_group (
			id TEXT PRIMARY KEY,
			name TEXT NOT NULL,
			note TEXT NOT NULL DEFAULT '',
			enabled INTEGER NOT NULL DEFAULT 1,
			sort INTEGER NOT NULL DEFAULT 0,
			created_at INTEGER NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS group_vod (
			group_id TEXT NOT NULL,
			config_id INTEGER NOT NULL,
			PRIMARY KEY (group_id, config_id)
		)`,
		`CREATE TABLE IF NOT EXISTS group_live (
			id TEXT PRIMARY KEY,
			group_id TEXT NOT NULL,
			name TEXT NOT NULL DEFAULT '',
			url TEXT NOT NULL DEFAULT '',
			sort INTEGER NOT NULL DEFAULT 0,
			enabled INTEGER NOT NULL DEFAULT 1
		)`,
		`CREATE INDEX IF NOT EXISTS idx_group_live_gid ON group_live(group_id)`,
		`CREATE TABLE IF NOT EXISTS group_setting (
			group_id TEXT NOT NULL,
			key TEXT NOT NULL,
			value TEXT NOT NULL DEFAULT '',
			PRIMARY KEY (group_id, key)
		)`,
		`CREATE TABLE IF NOT EXISTS group_site_hide (
			group_id TEXT NOT NULL,
			site_key TEXT NOT NULL,
			PRIMARY KEY (group_id, site_key)
		)`,
		`CREATE TABLE IF NOT EXISTS admin_notice (
			id TEXT PRIMARY KEY,
			scope TEXT NOT NULL,
			target_id TEXT NOT NULL DEFAULT '',
			kind TEXT NOT NULL DEFAULT 'banner',
			title TEXT NOT NULL DEFAULT '',
			body TEXT NOT NULL DEFAULT '',
			link TEXT NOT NULL DEFAULT '',
			sticky INTEGER NOT NULL DEFAULT 0,
			priority INTEGER NOT NULL DEFAULT 0,
			starts_at INTEGER NOT NULL DEFAULT 0,
			ends_at INTEGER NOT NULL DEFAULT 0,
			created_at INTEGER NOT NULL,
			created_by TEXT NOT NULL DEFAULT ''
		)`,
		`CREATE TABLE IF NOT EXISTS notice_ack (
			user_id TEXT NOT NULL,
			notice_id TEXT NOT NULL,
			acked_at INTEGER NOT NULL,
			PRIMARY KEY (user_id, notice_id)
		)`,
		`CREATE TABLE IF NOT EXISTS admin_push_log (
			id TEXT PRIMARY KEY,
			at INTEGER NOT NULL,
			actor TEXT NOT NULL DEFAULT '',
			target TEXT NOT NULL DEFAULT '',
			kind TEXT NOT NULL DEFAULT '',
			payload TEXT NOT NULL DEFAULT ''
		)`,
		`CREATE TABLE IF NOT EXISTS auth_invite (
			code TEXT PRIMARY KEY,
			group_id TEXT NOT NULL,
			max_uses INTEGER NOT NULL DEFAULT 1,
			used INTEGER NOT NULL DEFAULT 0,
			expires_at INTEGER NOT NULL DEFAULT 0
		)`,
		`CREATE TABLE IF NOT EXISTS auth_device (
			user_id TEXT NOT NULL,
			client_id TEXT NOT NULL,
			name TEXT NOT NULL DEFAULT '',
			last_seen INTEGER NOT NULL DEFAULT 0,
			created_at INTEGER NOT NULL,
			PRIMARY KEY (user_id, client_id)
		)`,
		`CREATE TABLE IF NOT EXISTS admin_audit (
			id TEXT PRIMARY KEY,
			at INTEGER NOT NULL,
			actor TEXT NOT NULL DEFAULT '',
			action TEXT NOT NULL DEFAULT '',
			target TEXT NOT NULL DEFAULT '',
			detail TEXT NOT NULL DEFAULT ''
		)`,
		`CREATE TABLE IF NOT EXISTS auth_login_log (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			at INTEGER NOT NULL,
			username TEXT NOT NULL DEFAULT '',
			user_id TEXT NOT NULL DEFAULT '',
			ok INTEGER NOT NULL DEFAULT 0,
			ip TEXT NOT NULL DEFAULT '',
			platform TEXT NOT NULL DEFAULT ''
		)`,
		`CREATE TABLE IF NOT EXISTS usage_event (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			at INTEGER NOT NULL,
			user_id TEXT NOT NULL DEFAULT '',
			group_id TEXT NOT NULL DEFAULT '',
			client_id TEXT NOT NULL DEFAULT '',
			platform TEXT NOT NULL DEFAULT '',
			arch TEXT NOT NULL DEFAULT '',
			app_ver TEXT NOT NULL DEFAULT '',
			protocol TEXT NOT NULL DEFAULT '',
			ip TEXT NOT NULL DEFAULT '',
			kind TEXT NOT NULL DEFAULT '',
			ref_type TEXT NOT NULL DEFAULT '',
			ref_id TEXT NOT NULL DEFAULT '',
			ref_name TEXT NOT NULL DEFAULT '',
			ok INTEGER NOT NULL DEFAULT 1,
			err_code TEXT NOT NULL DEFAULT '',
			latency_ms INTEGER NOT NULL DEFAULT 0,
			meta_json TEXT NOT NULL DEFAULT ''
		)`,
		`CREATE INDEX IF NOT EXISTS idx_usage_event_at ON usage_event(at)`,
		`CREATE INDEX IF NOT EXISTS idx_usage_event_kind ON usage_event(kind, at)`,
		`CREATE TABLE IF NOT EXISTS usage_daily (
			day TEXT NOT NULL,
			group_id TEXT NOT NULL DEFAULT '',
			platform TEXT NOT NULL DEFAULT '',
			kind TEXT NOT NULL DEFAULT '',
			ref_type TEXT NOT NULL DEFAULT '',
			ref_id TEXT NOT NULL DEFAULT '',
			count INTEGER NOT NULL DEFAULT 0,
			users INTEGER NOT NULL DEFAULT 0,
			PRIMARY KEY (day, group_id, platform, kind, ref_type, ref_id)
		)`,
	}
	for _, s := range stmts {
		if _, err := db.conn.Exec(s); err != nil {
			return fmt.Errorf("migrateAdminGroups: %w", err)
		}
	}
	alterUser := []string{
		`ALTER TABLE auth_user ADD COLUMN group_id TEXT NOT NULL DEFAULT ''`,
		`ALTER TABLE auth_user ADD COLUMN status TEXT NOT NULL DEFAULT 'active'`,
		`ALTER TABLE auth_user ADD COLUMN note TEXT NOT NULL DEFAULT ''`,
		`ALTER TABLE auth_user ADD COLUMN expires_at INTEGER NOT NULL DEFAULT 0`,
		`ALTER TABLE auth_user ADD COLUMN force_password_change INTEGER NOT NULL DEFAULT 0`,
	}
	for _, s := range alterUser {
		_, _ = db.conn.Exec(s)
	}
	return db.ensureDefaultGroup()
}

func (db *DB) ensureDefaultGroup() error {
	var n int
	_ = db.conn.QueryRow(`SELECT COUNT(1) FROM auth_group WHERE id = ?`, DefaultGroupID).Scan(&n)
	now := time.Now().UnixMilli()
	if n == 0 {
		_, err := db.conn.Exec(
			`INSERT INTO auth_group(id, name, note, enabled, sort, created_at) VALUES(?,?,?,?,?,?)`,
			DefaultGroupID, "默认", "迁移自动创建；含全部点播仓", 1, 0, now,
		)
		if err != nil {
			return err
		}
	}
	// 回填用户分组
	_, _ = db.conn.Exec(`UPDATE auth_user SET group_id = ? WHERE group_id IS NULL OR group_id = ''`, DefaultGroupID)
	// 默认组勾选全部点播仓。
	// 注意：DB MaxOpenConns=1，绝不能在 rows 未 Close 时再 Exec（会死锁卡住引擎启动）。
	rows, err := db.conn.Query(`SELECT id FROM config WHERE type = ?`, ConfigTypeSite)
	var vodIDs []int64
	if err == nil {
		for rows.Next() {
			var id int64
			if rows.Scan(&id) == nil && id > 0 {
				vodIDs = append(vodIDs, id)
			}
		}
		_ = rows.Close()
	}
	for _, id := range vodIDs {
		_, _ = db.conn.Exec(`INSERT OR IGNORE INTO group_vod(group_id, config_id) VALUES(?,?)`, DefaultGroupID, id)
	}
	// 若默认组尚无直播条目，从全局 live config 快照
	var liveN int
	_ = db.conn.QueryRow(`SELECT COUNT(1) FROM group_live WHERE group_id = ?`, DefaultGroupID).Scan(&liveN)
	if liveN == 0 {
		lives, _ := db.ListConfigs(int64(ConfigTypeLive))
		for i, c := range lives {
			url := strings.TrimSpace(c.URL)
			if url == "" {
				continue
			}
			id := fmt.Sprintf("gl-%d-%d", now, i)
			_, _ = db.conn.Exec(
				`INSERT INTO group_live(id, group_id, name, url, sort, enabled) VALUES(?,?,?,?,?,1)`,
				id, DefaultGroupID, strings.TrimSpace(c.Name), url, i,
			)
		}
	}
	return nil
}

func (db *DB) ListAuthGroups() ([]AuthGroup, error) {
	rows, err := db.conn.Query(`SELECT id, name, note, enabled, sort, created_at FROM auth_group ORDER BY sort, name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []AuthGroup
	for rows.Next() {
		var g AuthGroup
		var en, created int64
		if err := rows.Scan(&g.ID, &g.Name, &g.Note, &en, &g.Sort, &created); err != nil {
			return nil, err
		}
		g.Enabled = en != 0
		g.CreatedAt = time.UnixMilli(created).UTC()
		out = append(out, g)
	}
	return out, rows.Err()
}

func (db *DB) GetAuthGroup(id string) (*AuthGroup, error) {
	row := db.conn.QueryRow(`SELECT id, name, note, enabled, sort, created_at FROM auth_group WHERE id = ?`, id)
	var g AuthGroup
	var en, created int64
	err := row.Scan(&g.ID, &g.Name, &g.Note, &en, &g.Sort, &created)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	g.Enabled = en != 0
	g.CreatedAt = time.UnixMilli(created).UTC()
	return &g, nil
}

func (db *DB) UpsertAuthGroup(g AuthGroup) error {
	en := 0
	if g.Enabled {
		en = 1
	}
	ct := g.CreatedAt.UnixMilli()
	if ct == 0 {
		ct = time.Now().UnixMilli()
	}
	_, err := db.conn.Exec(
		`INSERT INTO auth_group(id, name, note, enabled, sort, created_at) VALUES(?,?,?,?,?,?)
		 ON CONFLICT(id) DO UPDATE SET name=excluded.name, note=excluded.note, enabled=excluded.enabled, sort=excluded.sort`,
		g.ID, g.Name, g.Note, en, g.Sort, ct,
	)
	return err
}

func (db *DB) DeleteAuthGroup(id string) error {
	if id == DefaultGroupID {
		return fmt.Errorf("不能删除默认分组")
	}
	tx, err := db.conn.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.Exec(`UPDATE auth_user SET group_id = ? WHERE group_id = ?`, DefaultGroupID, id); err != nil {
		return err
	}
	for _, q := range []string{
		`DELETE FROM group_vod WHERE group_id = ?`,
		`DELETE FROM group_live WHERE group_id = ?`,
		`DELETE FROM group_setting WHERE group_id = ?`,
		`DELETE FROM group_site_hide WHERE group_id = ?`,
		`DELETE FROM auth_group WHERE id = ?`,
	} {
		if _, err := tx.Exec(q, id); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (db *DB) ListGroupVodIDs(groupID string) ([]int64, error) {
	rows, err := db.conn.Query(`SELECT config_id FROM group_vod WHERE group_id = ?`, groupID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []int64
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

func (db *DB) SetGroupVods(groupID string, configIDs []int64) error {
	tx, err := db.conn.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.Exec(`DELETE FROM group_vod WHERE group_id = ?`, groupID); err != nil {
		return err
	}
	for _, id := range configIDs {
		if _, err := tx.Exec(`INSERT INTO group_vod(group_id, config_id) VALUES(?,?)`, groupID, id); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (db *DB) ListGroupLives(groupID string) ([]GroupLive, error) {
	rows, err := db.conn.Query(
		`SELECT id, group_id, name, url, sort, enabled FROM group_live WHERE group_id = ? ORDER BY sort, name`, groupID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []GroupLive
	for rows.Next() {
		var l GroupLive
		var en int
		if err := rows.Scan(&l.ID, &l.GroupID, &l.Name, &l.URL, &l.Sort, &en); err != nil {
			return nil, err
		}
		l.Enabled = en != 0
		out = append(out, l)
	}
	return out, rows.Err()
}

func (db *DB) ReplaceGroupLives(groupID string, lives []GroupLive) error {
	tx, err := db.conn.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.Exec(`DELETE FROM group_live WHERE group_id = ?`, groupID); err != nil {
		return err
	}
	for i, l := range lives {
		en := 0
		if l.Enabled {
			en = 1
		}
		id := strings.TrimSpace(l.ID)
		if id == "" {
			id = fmt.Sprintf("gl-%d-%d", time.Now().UnixMilli(), i)
		}
		sort := l.Sort
		if sort == 0 {
			sort = i
		}
		if _, err := tx.Exec(
			`INSERT INTO group_live(id, group_id, name, url, sort, enabled) VALUES(?,?,?,?,?,?)`,
			id, groupID, l.Name, l.URL, sort, en,
		); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (db *DB) ListGroupSettings(groupID string) (map[string]string, error) {
	rows, err := db.conn.Query(`SELECT key, value FROM group_setting WHERE group_id = ?`, groupID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var k, v string
		if err := rows.Scan(&k, &v); err != nil {
			return nil, err
		}
		out[k] = v
	}
	return out, rows.Err()
}

func (db *DB) SetGroupSettings(groupID string, kv map[string]string) error {
	tx, err := db.conn.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.Exec(`DELETE FROM group_setting WHERE group_id = ?`, groupID); err != nil {
		return err
	}
	for k, v := range kv {
		k = strings.TrimSpace(k)
		if k == "" {
			continue
		}
		if _, err := tx.Exec(`INSERT INTO group_setting(group_id, key, value) VALUES(?,?,?)`, groupID, k, v); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (db *DB) GetGroupSetting(groupID, key string) (string, error) {
	var v string
	err := db.conn.QueryRow(`SELECT value FROM group_setting WHERE group_id = ? AND key = ?`, groupID, key).Scan(&v)
	if err == sql.ErrNoRows {
		return "", nil
	}
	return v, err
}

func (db *DB) ListGroupSiteHides(groupID string) ([]string, error) {
	rows, err := db.conn.Query(`SELECT site_key FROM group_site_hide WHERE group_id = ?`, groupID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var k string
		if err := rows.Scan(&k); err != nil {
			return nil, err
		}
		out = append(out, k)
	}
	return out, rows.Err()
}

func (db *DB) SetGroupSiteHides(groupID string, keys []string) error {
	tx, err := db.conn.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.Exec(`DELETE FROM group_site_hide WHERE group_id = ?`, groupID); err != nil {
		return err
	}
	for _, k := range keys {
		k = strings.TrimSpace(k)
		if k == "" {
			continue
		}
		if _, err := tx.Exec(`INSERT INTO group_site_hide(group_id, site_key) VALUES(?,?)`, groupID, k); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (db *DB) SetAuthUserGroup(userID, groupID string) error {
	_, err := db.conn.Exec(`UPDATE auth_user SET group_id = ? WHERE id = ?`, groupID, userID)
	return err
}

func (db *DB) SetAuthUserExtras(userID, status, note string, expiresAt int64) error {
	_, err := db.conn.Exec(
		`UPDATE auth_user SET status = ?, note = ?, expires_at = ? WHERE id = ?`,
		status, note, expiresAt, userID,
	)
	return err
}

func (db *DB) SetAuthUserStatus(userID, status string) error {
	_, err := db.conn.Exec(`UPDATE auth_user SET status = ? WHERE id = ?`, status, userID)
	return err
}

func (db *DB) InsertUsageEvent(e UsageEvent) error {
	ok := 0
	if e.OK {
		ok = 1
	}
	at := e.At
	if at == 0 {
		at = time.Now().UnixMilli()
	}
	_, err := db.conn.Exec(
		`INSERT INTO usage_event(at,user_id,group_id,client_id,platform,arch,app_ver,protocol,ip,kind,ref_type,ref_id,ref_name,ok,err_code,latency_ms,meta_json)
		 VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
		at, e.UserID, e.GroupID, e.ClientID, e.Platform, e.Arch, e.AppVer, e.Protocol, e.IP,
		e.Kind, e.RefType, e.RefID, e.RefName, ok, e.ErrCode, e.Latency, e.MetaJSON,
	)
	return err
}

func (db *DB) InsertAdminAudit(id, actor, action, target, detail string) error {
	_, err := db.conn.Exec(
		`INSERT INTO admin_audit(id, at, actor, action, target, detail) VALUES(?,?,?,?,?,?)`,
		id, time.Now().UnixMilli(), actor, action, target, detail,
	)
	return err
}

func (db *DB) ListAdminAudit(limit int) ([]map[string]any, error) {
	if limit <= 0 {
		limit = 50
	}
	rows, err := db.conn.Query(
		`SELECT id, at, actor, action, target, detail FROM admin_audit ORDER BY at DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []map[string]any
	for rows.Next() {
		var id, actor, action, target, detail string
		var at int64
		if err := rows.Scan(&id, &at, &actor, &action, &target, &detail); err != nil {
			return nil, err
		}
		out = append(out, map[string]any{
			"id": id, "at": at, "actor": actor, "action": action, "target": target, "detail": detail,
		})
	}
	return out, rows.Err()
}

func (db *DB) InsertLoginLog(username, userID string, ok bool, ip, platform string) error {
	o := 0
	if ok {
		o = 1
	}
	_, err := db.conn.Exec(
		`INSERT INTO auth_login_log(at, username, user_id, ok, ip, platform) VALUES(?,?,?,?,?,?)`,
		time.Now().UnixMilli(), username, userID, o, ip, platform,
	)
	return err
}

func (db *DB) UpsertAuthDevice(userID, clientID, name string) error {
	now := time.Now().UnixMilli()
	_, err := db.conn.Exec(
		`INSERT INTO auth_device(user_id, client_id, name, last_seen, created_at) VALUES(?,?,?,?,?)
		 ON CONFLICT(user_id, client_id) DO UPDATE SET name=excluded.name, last_seen=excluded.last_seen`,
		userID, clientID, name, now, now,
	)
	return err
}

func (db *DB) ListAuthDevices(userID string) ([]map[string]any, error) {
	rows, err := db.conn.Query(
		`SELECT client_id, name, last_seen, created_at FROM auth_device WHERE user_id = ? ORDER BY last_seen DESC`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []map[string]any
	for rows.Next() {
		var cid, name string
		var last, created int64
		if err := rows.Scan(&cid, &name, &last, &created); err != nil {
			return nil, err
		}
		out = append(out, map[string]any{"clientId": cid, "name": name, "lastSeen": last, "createdAt": created})
	}
	return out, rows.Err()
}

func (db *DB) DeleteAuthDevice(userID, clientID string) error {
	_, err := db.conn.Exec(`DELETE FROM auth_device WHERE user_id = ? AND client_id = ?`, userID, clientID)
	return err
}

func (db *DB) CountAuthDevices(userID string) (int, error) {
	var n int
	err := db.conn.QueryRow(`SELECT COUNT(1) FROM auth_device WHERE user_id = ?`, userID).Scan(&n)
	return n, err
}

func (db *DB) UpsertAdminNotice(n AdminNotice) error {
	st := 0
	if n.Sticky {
		st = 1
	}
	if n.CreatedAt == 0 {
		n.CreatedAt = time.Now().UnixMilli()
	}
	_, err := db.conn.Exec(
		`INSERT INTO admin_notice(id,scope,target_id,kind,title,body,link,sticky,priority,starts_at,ends_at,created_at,created_by)
		 VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
		 ON CONFLICT(id) DO UPDATE SET
		   scope=excluded.scope, target_id=excluded.target_id, kind=excluded.kind, title=excluded.title,
		   body=excluded.body, link=excluded.link, sticky=excluded.sticky, priority=excluded.priority,
		   starts_at=excluded.starts_at, ends_at=excluded.ends_at`,
		n.ID, n.Scope, n.TargetID, n.Kind, n.Title, n.Body, n.Link, st, n.Priority, n.StartsAt, n.EndsAt, n.CreatedAt, n.CreatedBy,
	)
	return err
}

func (db *DB) DeleteAdminNotice(id string) error {
	_, err := db.conn.Exec(`DELETE FROM admin_notice WHERE id = ?`, id)
	return err
}

func (db *DB) ListAdminNotices() ([]AdminNotice, error) {
	rows, err := db.conn.Query(
		`SELECT id,scope,target_id,kind,title,body,link,sticky,priority,starts_at,ends_at,created_at,created_by
		 FROM admin_notice ORDER BY priority DESC, created_at DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []AdminNotice
	for rows.Next() {
		var n AdminNotice
		var st int
		if err := rows.Scan(&n.ID, &n.Scope, &n.TargetID, &n.Kind, &n.Title, &n.Body, &n.Link, &st, &n.Priority, &n.StartsAt, &n.EndsAt, &n.CreatedAt, &n.CreatedBy); err != nil {
			return nil, err
		}
		n.Sticky = st != 0
		out = append(out, n)
	}
	return out, rows.Err()
}

func (db *DB) AckNotice(userID, noticeID string) error {
	_, err := db.conn.Exec(
		`INSERT OR REPLACE INTO notice_ack(user_id, notice_id, acked_at) VALUES(?,?,?)`,
		userID, noticeID, time.Now().UnixMilli(),
	)
	return err
}

func (db *DB) NoticeAcked(userID, noticeID string) bool {
	var n int
	_ = db.conn.QueryRow(`SELECT COUNT(1) FROM notice_ack WHERE user_id = ? AND notice_id = ?`, userID, noticeID).Scan(&n)
	return n > 0
}

func (db *DB) InsertPushLog(id, actor, target, kind, payload string) error {
	_, err := db.conn.Exec(
		`INSERT INTO admin_push_log(id, at, actor, target, kind, payload) VALUES(?,?,?,?,?,?)`,
		id, time.Now().UnixMilli(), actor, target, kind, payload,
	)
	return err
}

func (db *DB) ListPushLog(limit int) ([]map[string]any, error) {
	if limit <= 0 {
		limit = 50
	}
	rows, err := db.conn.Query(
		`SELECT id, at, actor, target, kind, payload FROM admin_push_log ORDER BY at DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make([]map[string]any, 0)
	for rows.Next() {
		var id, actor, target, kind, payload string
		var at int64
		if err := rows.Scan(&id, &at, &actor, &target, &kind, &payload); err != nil {
			return nil, err
		}
		out = append(out, map[string]any{
			"id": id, "at": at, "actor": actor, "target": target, "kind": kind, "payload": payload,
		})
	}
	return out, rows.Err()
}

func (db *DB) CountNoticeAcks(noticeID string) (int, error) {
	var n int
	err := db.conn.QueryRow(`SELECT COUNT(1) FROM notice_ack WHERE notice_id = ?`, noticeID).Scan(&n)
	return n, err
}

func (db *DB) UpsertInvite(code, groupID string, maxUses int, expiresAt int64) error {
	if maxUses <= 0 {
		maxUses = 1
	}
	_, err := db.conn.Exec(
		`INSERT INTO auth_invite(code, group_id, max_uses, used, expires_at) VALUES(?,?,?,0,?)
		 ON CONFLICT(code) DO UPDATE SET group_id=excluded.group_id, max_uses=excluded.max_uses, expires_at=excluded.expires_at`,
		code, groupID, maxUses, expiresAt,
	)
	return err
}

func (db *DB) ListInvites() ([]map[string]any, error) {
	rows, err := db.conn.Query(`SELECT code, group_id, max_uses, used, expires_at FROM auth_invite ORDER BY code`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []map[string]any
	for rows.Next() {
		var code, gid string
		var max, used int
		var exp int64
		if err := rows.Scan(&code, &gid, &max, &used, &exp); err != nil {
			return nil, err
		}
		out = append(out, map[string]any{"code": code, "groupId": gid, "maxUses": max, "used": used, "expiresAt": exp})
	}
	return out, rows.Err()
}

func (db *DB) DeleteInvite(code string) error {
	_, err := db.conn.Exec(`DELETE FROM auth_invite WHERE code = ?`, code)
	return err
}

func (db *DB) ConsumeInvite(code string) (groupID string, err error) {
	code = strings.TrimSpace(code)
	if code == "" {
		return "", fmt.Errorf("邀请码为空")
	}
	tx, err := db.conn.Begin()
	if err != nil {
		return "", err
	}
	defer func() { _ = tx.Rollback() }()
	var gid string
	var max, used int
	var exp int64
	err = tx.QueryRow(`SELECT group_id, max_uses, used, expires_at FROM auth_invite WHERE code = ?`, code).
		Scan(&gid, &max, &used, &exp)
	if err == sql.ErrNoRows {
		return "", fmt.Errorf("邀请码无效")
	}
	if err != nil {
		return "", err
	}
	if exp > 0 && time.Now().UnixMilli() > exp {
		return "", fmt.Errorf("邀请码已过期")
	}
	if used >= max {
		return "", fmt.Errorf("邀请码已用尽")
	}
	if _, err := tx.Exec(`UPDATE auth_invite SET used = used + 1 WHERE code = ?`, code); err != nil {
		return "", err
	}
	return gid, tx.Commit()
}

func (db *DB) GetConfigByID(id int64) (*Config, error) {
	row := db.conn.QueryRow(configSelect+`WHERE id = ?`, id)
	return scanConfig(row)
}

func (db *DB) StatsSummary(from, to int64, groupID, platform string) (map[string]any, error) {
	where := `at >= ? AND at <= ?`
	args := []any{from, to}
	if groupID != "" {
		where += ` AND group_id = ?`
		args = append(args, groupID)
	}
	if platform != "" {
		where += ` AND platform = ?`
		args = append(args, platform)
	}
	countKind := func(kind string) int {
		var n int
		q := `SELECT COUNT(1) FROM usage_event WHERE ` + where + ` AND kind = ?`
		a := append(append([]any{}, args...), kind)
		_ = db.conn.QueryRow(q, a...).Scan(&n)
		return n
	}
	var dau int
	_ = db.conn.QueryRow(
		`SELECT COUNT(DISTINCT CASE WHEN user_id != '' THEN user_id ELSE client_id END) FROM usage_event WHERE `+where,
		args...,
	).Scan(&dau)
	var fails int
	_ = db.conn.QueryRow(`SELECT COUNT(1) FROM usage_event WHERE `+where+` AND ok = 0`, args...).Scan(&fails)
	var total int
	_ = db.conn.QueryRow(`SELECT COUNT(1) FROM usage_event WHERE `+where, args...).Scan(&total)
	errRate := 0.0
	if total > 0 {
		errRate = float64(fails) / float64(total)
	}
	return map[string]any{
		"dau":       dau,
		"plays":     countKind("play"),
		"livePlays": countKind("live_play"),
		"searches":  countKind("search"),
		"configLoads": countKind("config_load"),
		"errors":    fails,
		"errorRate": errRate,
		"events":    total,
	}, nil
}

func (db *DB) StatsTopRefs(from, to int64, kind, groupID string, limit int) ([]map[string]any, error) {
	if limit <= 0 {
		limit = 20
	}
	where := `at >= ? AND at <= ? AND kind = ?`
	args := []any{from, to, kind}
	if groupID != "" {
		where += ` AND group_id = ?`
		args = append(args, groupID)
	}
	args = append(args, limit)
	rows, err := db.conn.Query(
		`SELECT ref_id, ref_name, COUNT(1) AS c, COUNT(DISTINCT user_id) AS u
		 FROM usage_event WHERE `+where+`
		 GROUP BY ref_id, ref_name ORDER BY c DESC LIMIT ?`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []map[string]any
	for rows.Next() {
		var id, name string
		var c, u int
		if err := rows.Scan(&id, &name, &c, &u); err != nil {
			return nil, err
		}
		out = append(out, map[string]any{"refId": id, "refName": name, "count": c, "users": u})
	}
	return out, rows.Err()
}

// StatsFailedRefs 按失败事件聚合（ok=0），用于错误 Top。
func (db *DB) StatsFailedRefs(from, to int64, groupID string, limit int) ([]map[string]any, error) {
	if limit <= 0 {
		limit = 20
	}
	where := `at >= ? AND at <= ? AND ok = 0`
	args := []any{from, to}
	if groupID != "" {
		where += ` AND group_id = ?`
		args = append(args, groupID)
	}
	args = append(args, limit)
	rows, err := db.conn.Query(
		`SELECT COALESCE(NULLIF(kind,''),'unknown'), COALESCE(NULLIF(ref_name,''), NULLIF(ref_id,''), err_code, '—'),
		        COUNT(1) AS c, COUNT(DISTINCT user_id) AS u
		 FROM usage_event WHERE `+where+`
		 GROUP BY 1, 2 ORDER BY c DESC LIMIT ?`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []map[string]any
	for rows.Next() {
		var id, name string
		var c, u int
		if err := rows.Scan(&id, &name, &c, &u); err != nil {
			return nil, err
		}
		out = append(out, map[string]any{"refId": id, "refName": name, "count": c, "users": u})
	}
	return out, rows.Err()
}

func (db *DB) StatsPlatforms(from, to int64, groupID string) ([]map[string]any, error) {
	where := `at >= ? AND at <= ?`
	args := []any{from, to}
	if groupID != "" {
		where += ` AND group_id = ?`
		args = append(args, groupID)
	}
	rows, err := db.conn.Query(
		`SELECT COALESCE(NULLIF(platform,''),'unknown'), COUNT(DISTINCT CASE WHEN user_id != '' THEN user_id ELSE client_id END)
		 FROM usage_event WHERE `+where+` GROUP BY 1 ORDER BY 2 DESC`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []map[string]any
	for rows.Next() {
		var p string
		var n int
		if err := rows.Scan(&p, &n); err != nil {
			return nil, err
		}
		out = append(out, map[string]any{"platform": p, "users": n})
	}
	return out, rows.Err()
}

func (db *DB) PurgeOldUsageEvents(beforeMs int64) error {
	_, err := db.conn.Exec(`DELETE FROM usage_event WHERE at < ?`, beforeMs)
	return err
}
