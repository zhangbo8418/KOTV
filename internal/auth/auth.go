package auth

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"log"
	"strings"
	"sync"
	"time"

	"github.com/bobo/KOTV/internal/database"
	"github.com/bobo/KOTV/internal/settings"
	"golang.org/x/crypto/bcrypt"
)

const (
	RoleAdmin = "admin"
	RoleUser  = "user"
	tokenTTL  = 30 * 24 * time.Hour
)

// User 远端引擎账号。
type User struct {
	ID                 string    `json:"id"`
	Username           string    `json:"username"`
	PassHash           string    `json:"passHash"`
	Role               string    `json:"role"`
	Enabled            bool      `json:"enabled"`
	MustChangePassword bool      `json:"mustChangePassword,omitempty"`
	CreatedAt          time.Time `json:"createdAt"`
}

// Public 返回不含密码哈希的视图。
func (u User) Public() map[string]any {
	return map[string]any{
		"id":                 u.ID,
		"username":           u.Username,
		"role":               u.Role,
		"enabled":            u.Enabled,
		"mustChangePassword": u.MustChangePassword,
		"createdAt":          u.CreatedAt.UTC().Format(time.RFC3339),
	}
}

var (
	mu  sync.Mutex
	store *database.DB
)

// BindDB 绑定 SQLite（须在 Init 前调用）。
func BindDB(db *database.DB) { store = db }

func requireDB() (*database.DB, error) {
	if store == nil {
		return nil, fmt.Errorf("auth: database not bound")
	}
	return store, nil
}

func fromRow(u *database.AuthUser) *User {
	if u == nil {
		return nil
	}
	return &User{
		ID:                 u.ID,
		Username:           u.Username,
		PassHash:           u.PassHash,
		Role:               u.Role,
		Enabled:            u.Enabled,
		MustChangePassword: u.MustChangePassword,
		CreatedAt:          u.CreatedAt,
	}
}

func toRow(u User) database.AuthUser {
	return database.AuthUser{
		ID:                 u.ID,
		Username:           u.Username,
		PassHash:           u.PassHash,
		Role:               u.Role,
		Enabled:            u.Enabled,
		MustChangePassword: u.MustChangePassword,
		CreatedAt:          u.CreatedAt,
	}
}

func newID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// Init 确保至少有一名管理员。
func Init() error {
	mu.Lock()
	defer mu.Unlock()
	db, err := requireDB()
	if err != nil {
		return err
	}
	_ = db.DeleteExpiredAuthTokens()
	n, err := db.CountAuthAdmins()
	if err != nil {
		return err
	}
	if n == 0 {
		return bootstrapAdminLocked(db)
	}
	return nil
}

func bootstrapAdminLocked(db *database.DB) error {
	const pass = "admin"
	hash, err := bcrypt.GenerateFromPassword([]byte(pass), bcrypt.DefaultCost)
	if err != nil {
		return err
	}
	u := User{
		ID:                 newID(),
		Username:           "admin",
		PassHash:           string(hash),
		Role:               RoleAdmin,
		Enabled:            true,
		MustChangePassword: true,
		CreatedAt:          time.Now().UTC(),
	}
	if err := db.UpsertAuthUser(toRow(u)); err != nil {
		return err
	}
	log.Printf("auth: 已创建初始管理员 admin（默认密码 admin，请尽快修改）")
	return nil
}

// RemoteAuthEnabled 是否强制远端鉴权。
func RemoteAuthEnabled() bool {
	v := strings.ToLower(strings.TrimSpace(settings.Get(settings.RemoteAuth)))
	return v == "true" || v == "1" || v == "yes"
}

// AllowRegister 是否开放注册。
func AllowRegister() bool {
	v := strings.ToLower(strings.TrimSpace(settings.Get(settings.AllowRegister)))
	return v == "true" || v == "1" || v == "yes"
}

// SetRemoteAuth / SetAllowRegister 供管理页写入。
func SetRemoteAuth(on bool) error {
	if on {
		settings.Set(settings.RemoteAuth, "true")
	} else {
		settings.Set(settings.RemoteAuth, "false")
	}
	return settings.Save()
}

func SetAllowRegister(on bool) error {
	if on {
		settings.Set(settings.AllowRegister, "true")
	} else {
		settings.Set(settings.AllowRegister, "false")
	}
	return settings.Save()
}

// Login 校验用户名密码并发 token。
func Login(username, password string) (token string, user User, err error) {
	username = strings.TrimSpace(username)
	password = strings.TrimSpace(password)
	if username == "" || password == "" {
		return "", User{}, fmt.Errorf("用户名或密码为空")
	}
	mu.Lock()
	defer mu.Unlock()
	db, err := requireDB()
	if err != nil {
		return "", User{}, err
	}
	row, err := db.GetAuthUserByName(username)
	if err != nil {
		return "", User{}, err
	}
	u := fromRow(row)
	if u == nil || !u.Enabled {
		return "", User{}, fmt.Errorf("用户名或密码错误")
	}
	if bcrypt.CompareHashAndPassword([]byte(u.PassHash), []byte(password)) != nil {
		return "", User{}, fmt.Errorf("用户名或密码错误")
	}
	tok := newID() + newID()
	rec := database.AuthToken{Token: tok, UserID: u.ID, ExpiresAt: time.Now().Add(tokenTTL)}
	if err := db.InsertAuthToken(rec); err != nil {
		return "", User{}, err
	}
	return tok, *u, nil
}

// Register 开放注册。
func Register(username, password string) (User, error) {
	if !AllowRegister() {
		return User{}, fmt.Errorf("未开放注册")
	}
	username = strings.TrimSpace(username)
	password = strings.TrimSpace(password)
	if len(username) < 2 || len(username) > 32 {
		return User{}, fmt.Errorf("用户名长度需 2–32")
	}
	if len(password) < 6 {
		return User{}, fmt.Errorf("密码至少 6 位")
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return User{}, err
	}
	mu.Lock()
	defer mu.Unlock()
	db, err := requireDB()
	if err != nil {
		return User{}, err
	}
	if existing, err := db.GetAuthUserByName(username); err != nil {
		return User{}, err
	} else if existing != nil {
		return User{}, fmt.Errorf("用户名已存在")
	}
	u := User{
		ID:        newID(),
		Username:  username,
		PassHash:  string(hash),
		Role:      RoleUser,
		Enabled:   true,
		CreatedAt: time.Now().UTC(),
	}
	if err := db.UpsertAuthUser(toRow(u)); err != nil {
		return User{}, err
	}
	return u, nil
}

// Logout 作废 token。
func Logout(token string) {
	token = strings.TrimSpace(token)
	if token == "" {
		return
	}
	mu.Lock()
	defer mu.Unlock()
	if db, err := requireDB(); err == nil {
		_ = db.DeleteAuthToken(token)
	}
}

// LookupToken 返回有效用户。
func LookupToken(token string) (*User, error) {
	token = strings.TrimSpace(token)
	if token == "" {
		return nil, fmt.Errorf("未登录")
	}
	mu.Lock()
	defer mu.Unlock()
	db, err := requireDB()
	if err != nil {
		return nil, err
	}
	rec, err := db.LookupAuthToken(token)
	if err != nil {
		return nil, err
	}
	if rec == nil || rec.ExpiresAt.Before(time.Now()) {
		if rec != nil {
			_ = db.DeleteAuthToken(token)
		}
		return nil, fmt.Errorf("登录已失效")
	}
	row, err := db.GetAuthUser(rec.UserID)
	if err != nil {
		return nil, err
	}
	u := fromRow(row)
	if u == nil || !u.Enabled {
		return nil, fmt.Errorf("用户不可用")
	}
	cp := *u
	return &cp, nil
}

// ListUsers 管理员用。
func ListUsers() []User {
	mu.Lock()
	defer mu.Unlock()
	db, err := requireDB()
	if err != nil {
		return nil
	}
	rows, err := db.ListAuthUsers()
	if err != nil {
		return nil
	}
	out := make([]User, 0, len(rows))
	for i := range rows {
		if u := fromRow(&rows[i]); u != nil {
			out = append(out, *u)
		}
	}
	return out
}

// CreateUser 管理员创建。
func CreateUser(username, password, role string) (User, error) {
	username = strings.TrimSpace(username)
	password = strings.TrimSpace(password)
	role = strings.TrimSpace(role)
	if role != RoleAdmin {
		role = RoleUser
	}
	if len(username) < 2 {
		return User{}, fmt.Errorf("用户名过短")
	}
	if len(password) < 6 {
		return User{}, fmt.Errorf("密码至少 6 位")
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return User{}, err
	}
	mu.Lock()
	defer mu.Unlock()
	db, err := requireDB()
	if err != nil {
		return User{}, err
	}
	if existing, err := db.GetAuthUserByName(username); err != nil {
		return User{}, err
	} else if existing != nil {
		return User{}, fmt.Errorf("用户名已存在")
	}
	u := User{
		ID:        newID(),
		Username:  username,
		PassHash:  string(hash),
		Role:      role,
		Enabled:   true,
		CreatedAt: time.Now().UTC(),
	}
	if err := db.UpsertAuthUser(toRow(u)); err != nil {
		return User{}, err
	}
	return u, nil
}

// SetEnabled 启用/禁用；禁用时撤销全部 token。
func SetEnabled(userID string, enabled bool) error {
	mu.Lock()
	defer mu.Unlock()
	db, err := requireDB()
	if err != nil {
		return err
	}
	row, err := db.GetAuthUser(userID)
	if err != nil {
		return err
	}
	u := fromRow(row)
	if u == nil {
		return fmt.Errorf("用户不存在")
	}
	if u.Role == RoleAdmin && !enabled {
		n, err := db.CountAuthAdmins()
		if err != nil {
			return err
		}
		if n <= 1 {
			return fmt.Errorf("不能禁用唯一管理员")
		}
	}
	u.Enabled = enabled
	if err := db.UpsertAuthUser(toRow(*u)); err != nil {
		return err
	}
	if !enabled {
		_ = db.DeleteAuthTokensForUser(userID)
	}
	return nil
}

// ResetPassword 管理员重置密码。
func ResetPassword(userID, password string) error {
	password = strings.TrimSpace(password)
	if len(password) < 6 {
		return fmt.Errorf("密码至少 6 位")
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return err
	}
	mu.Lock()
	defer mu.Unlock()
	db, err := requireDB()
	if err != nil {
		return err
	}
	row, err := db.GetAuthUser(userID)
	if err != nil {
		return err
	}
	u := fromRow(row)
	if u == nil {
		return fmt.Errorf("用户不存在")
	}
	u.PassHash = string(hash)
	u.MustChangePassword = false
	return db.UpsertAuthUser(toRow(*u))
}

// ChangePassword 登录用户修改自己的密码。
func ChangePassword(userID, oldPassword, newPassword string) error {
	oldPassword = strings.TrimSpace(oldPassword)
	newPassword = strings.TrimSpace(newPassword)
	if len(newPassword) < 6 {
		return fmt.Errorf("密码至少 6 位")
	}
	if oldPassword == newPassword {
		return fmt.Errorf("新密码不能与旧密码相同")
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(newPassword), bcrypt.DefaultCost)
	if err != nil {
		return err
	}
	mu.Lock()
	defer mu.Unlock()
	db, err := requireDB()
	if err != nil {
		return err
	}
	row, err := db.GetAuthUser(userID)
	if err != nil {
		return err
	}
	u := fromRow(row)
	if u == nil || !u.Enabled {
		return fmt.Errorf("用户不可用")
	}
	if bcrypt.CompareHashAndPassword([]byte(u.PassHash), []byte(oldPassword)) != nil {
		return fmt.Errorf("旧密码错误")
	}
	u.PassHash = string(hash)
	u.MustChangePassword = false
	return db.UpsertAuthUser(toRow(*u))
}

// DeleteUser 删除用户（不可删唯一管理员）。账号行删除；用户态由 App.PurgeUserData 清理。
func DeleteUser(userID string) error {
	mu.Lock()
	defer mu.Unlock()
	db, err := requireDB()
	if err != nil {
		return err
	}
	row, err := db.GetAuthUser(userID)
	if err != nil {
		return err
	}
	u := fromRow(row)
	if u == nil {
		return fmt.Errorf("用户不存在")
	}
	if u.Role == RoleAdmin {
		n, err := db.CountAuthAdmins()
		if err != nil {
			return err
		}
		if n <= 1 {
			return fmt.Errorf("不能删除唯一管理员")
		}
	}
	_ = db.DeleteAuthTokensForUser(userID)
	return db.DeleteAuthUser(userID)
}

// GetUser 按 ID。
func GetUser(id string) *User {
	mu.Lock()
	defer mu.Unlock()
	db, err := requireDB()
	if err != nil {
		return nil
	}
	row, err := db.GetAuthUser(id)
	if err != nil {
		return nil
	}
	return fromRow(row)
}

// BearerFromHeader 解析 Authorization: Bearer。
func BearerFromHeader(h string) string {
	h = strings.TrimSpace(h)
	if len(h) < 8 {
		return ""
	}
	if !strings.EqualFold(h[:7], "Bearer ") {
		return ""
	}
	return strings.TrimSpace(h[7:])
}
