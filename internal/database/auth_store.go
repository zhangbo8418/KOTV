package database

import (
	"database/sql"
	"strings"
	"time"
)

// AuthUser 账号行。
type AuthUser struct {
	ID                 string
	Username           string
	PassHash           string
	Role               string
	Enabled            bool
	MustChangePassword bool
	CreatedAt          time.Time
}

// AuthToken 登录 token。
type AuthToken struct {
	Token     string
	UserID    string
	ExpiresAt time.Time
}

func (db *DB) ListAuthUsers() ([]AuthUser, error) {
	rows, err := db.conn.Query(
		`SELECT id, username, pass_hash, role, enabled, must_change_password, created_at FROM auth_user`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []AuthUser
	for rows.Next() {
		var u AuthUser
		var en, mcp int
		var created int64
		if err := rows.Scan(&u.ID, &u.Username, &u.PassHash, &u.Role, &en, &mcp, &created); err != nil {
			return nil, err
		}
		u.Enabled = en != 0
		u.MustChangePassword = mcp != 0
		u.CreatedAt = time.UnixMilli(created).UTC()
		out = append(out, u)
	}
	return out, rows.Err()
}

func (db *DB) GetAuthUser(id string) (*AuthUser, error) {
	row := db.conn.QueryRow(
		`SELECT id, username, pass_hash, role, enabled, must_change_password, created_at FROM auth_user WHERE id = ?`, id)
	return scanAuthUser(row)
}

func (db *DB) GetAuthUserByName(username string) (*AuthUser, error) {
	row := db.conn.QueryRow(
		`SELECT id, username, pass_hash, role, enabled, must_change_password, created_at FROM auth_user WHERE username = ? COLLATE NOCASE`,
		strings.TrimSpace(username))
	return scanAuthUser(row)
}

func scanAuthUser(row *sql.Row) (*AuthUser, error) {
	var u AuthUser
	var en, mcp int
	var created int64
	err := row.Scan(&u.ID, &u.Username, &u.PassHash, &u.Role, &en, &mcp, &created)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	u.Enabled = en != 0
	u.MustChangePassword = mcp != 0
	u.CreatedAt = time.UnixMilli(created).UTC()
	return &u, nil
}

func (db *DB) UpsertAuthUser(u AuthUser) error {
	en, mcp := 0, 0
	if u.Enabled {
		en = 1
	}
	if u.MustChangePassword {
		mcp = 1
	}
	ct := u.CreatedAt.UnixMilli()
	if ct == 0 {
		ct = time.Now().UnixMilli()
	}
	_, err := db.conn.Exec(
		`INSERT INTO auth_user(id, username, pass_hash, role, enabled, must_change_password, created_at)
		 VALUES(?,?,?,?,?,?,?)
		 ON CONFLICT(id) DO UPDATE SET
		   username=excluded.username,
		   pass_hash=excluded.pass_hash,
		   role=excluded.role,
		   enabled=excluded.enabled,
		   must_change_password=excluded.must_change_password`,
		u.ID, u.Username, u.PassHash, u.Role, en, mcp, ct,
	)
	return err
}

func (db *DB) DeleteAuthUser(id string) error {
	_, err := db.conn.Exec(`DELETE FROM auth_user WHERE id = ?`, id)
	return err
}

func (db *DB) CountAuthAdmins() (int, error) {
	var n int
	err := db.conn.QueryRow(
		`SELECT COUNT(1) FROM auth_user WHERE role = 'admin' AND enabled = 1`).Scan(&n)
	return n, err
}

func (db *DB) InsertAuthToken(t AuthToken) error {
	_, err := db.conn.Exec(
		`INSERT OR REPLACE INTO auth_token(token, user_id, expires_at) VALUES(?,?,?)`,
		t.Token, t.UserID, t.ExpiresAt.UnixMilli(),
	)
	return err
}

func (db *DB) DeleteAuthToken(token string) error {
	_, err := db.conn.Exec(`DELETE FROM auth_token WHERE token = ?`, token)
	return err
}

func (db *DB) DeleteAuthTokensForUser(userID string) error {
	_, err := db.conn.Exec(`DELETE FROM auth_token WHERE user_id = ?`, userID)
	return err
}

func (db *DB) LookupAuthToken(token string) (*AuthToken, error) {
	row := db.conn.QueryRow(
		`SELECT token, user_id, expires_at FROM auth_token WHERE token = ?`, token)
	var t AuthToken
	var exp int64
	err := row.Scan(&t.Token, &t.UserID, &exp)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	t.ExpiresAt = time.UnixMilli(exp).UTC()
	return &t, nil
}

func (db *DB) DeleteExpiredAuthTokens() error {
	_, err := db.conn.Exec(`DELETE FROM auth_token WHERE expires_at < ?`, time.Now().UnixMilli())
	return err
}
