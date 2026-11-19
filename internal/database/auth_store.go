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
	GroupID            string
	Status             string // active|pending|disabled
	Note               string
	ExpiresAt          int64
}

// AuthToken 登录 token。
type AuthToken struct {
	Token     string
	UserID    string
	ExpiresAt time.Time
}

const authUserSelect = `SELECT id, username, pass_hash, role, enabled, must_change_password, created_at,
	COALESCE(group_id,''), COALESCE(status,'active'), COALESCE(note,''), COALESCE(expires_at,0) FROM auth_user`

func (db *DB) ListAuthUsers() ([]AuthUser, error) {
	rows, err := db.conn.Query(authUserSelect)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []AuthUser
	for rows.Next() {
		u, err := scanAuthUserRow(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *u)
	}
	return out, rows.Err()
}

func (db *DB) GetAuthUser(id string) (*AuthUser, error) {
	row := db.conn.QueryRow(authUserSelect+` WHERE id = ?`, id)
	return scanAuthUser(row)
}

func (db *DB) GetAuthUserByName(username string) (*AuthUser, error) {
	row := db.conn.QueryRow(authUserSelect+` WHERE username = ? COLLATE NOCASE`,
		strings.TrimSpace(username))
	return scanAuthUser(row)
}

func scanAuthUser(row *sql.Row) (*AuthUser, error) {
	u, err := scanAuthUserRow(row)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	return u, err
}

type scanner interface {
	Scan(dest ...any) error
}

func scanAuthUserRow(row scanner) (*AuthUser, error) {
	var u AuthUser
	var en, mcp int
	var created int64
	err := row.Scan(&u.ID, &u.Username, &u.PassHash, &u.Role, &en, &mcp, &created,
		&u.GroupID, &u.Status, &u.Note, &u.ExpiresAt)
	if err != nil {
		return nil, err
	}
	u.Enabled = en != 0
	u.MustChangePassword = mcp != 0
	u.CreatedAt = time.UnixMilli(created).UTC()
	if u.Status == "" {
		u.Status = "active"
	}
	if u.GroupID == "" {
		u.GroupID = DefaultGroupID
	}
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
	if u.GroupID == "" {
		u.GroupID = DefaultGroupID
	}
	if u.Status == "" {
		u.Status = "active"
	}
	_, err := db.conn.Exec(
		`INSERT INTO auth_user(id, username, pass_hash, role, enabled, must_change_password, created_at, group_id, status, note, expires_at)
		 VALUES(?,?,?,?,?,?,?,?,?,?,?)
		 ON CONFLICT(id) DO UPDATE SET
		   username=excluded.username,
		   pass_hash=excluded.pass_hash,
		   role=excluded.role,
		   enabled=excluded.enabled,
		   must_change_password=excluded.must_change_password,
		   group_id=excluded.group_id,
		   status=excluded.status,
		   note=excluded.note,
		   expires_at=excluded.expires_at`,
		u.ID, u.Username, u.PassHash, u.Role, en, mcp, ct, u.GroupID, u.Status, u.Note, u.ExpiresAt,
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

func (db *DB) DeleteAuthTokensForUserExcept(userID, keep string) error {
	_, err := db.conn.Exec(`DELETE FROM auth_token WHERE user_id = ? AND token <> ?`, userID, keep)
	return err
}

func (db *DB) CountAuthTokensForUser(userID string) (int, error) {
	var n int
	err := db.conn.QueryRow(`SELECT COUNT(1) FROM auth_token WHERE user_id = ?`, userID).Scan(&n)
	return n, err
}

// TrimAuthTokensKeepNewest 超额时删最旧 token，保留 keep 条（含刚签发的）。
func (db *DB) TrimAuthTokensKeepNewest(userID string, keep int) error {
	if keep <= 0 {
		return nil
	}
	_, err := db.conn.Exec(
		`DELETE FROM auth_token WHERE user_id = ? AND token NOT IN (
			SELECT token FROM auth_token WHERE user_id = ? ORDER BY expires_at DESC LIMIT ?
		)`,
		userID, userID, keep,
	)
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
