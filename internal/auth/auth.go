package auth

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/bobo/KOTV/internal/paths"
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
	Role               string    `json:"role"` // admin | user
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

type tokenRec struct {
	Token     string    `json:"token"`
	UserID    string    `json:"userId"`
	ExpiresAt time.Time `json:"expiresAt"`
}

type storeFile struct {
	Users []User `json:"users"`
}

type tokenFile struct {
	Tokens []tokenRec `json:"tokens"`
}

var (
	mu     sync.Mutex
	users  = map[string]*User{} // id -> user
	byName = map[string]*User{} // lower username -> user
	tokens = map[string]*tokenRec{}
)

func usersPath() string  { return filepath.Join(paths.Data(), "users.json") }
func tokensPath() string { return filepath.Join(paths.Data(), "tokens.json") }
func bootstrapPath() string {
	return filepath.Join(paths.Data(), "admin_bootstrap.txt")
}

// Init 加载用户与 token；无管理员时生成一次性管理员。
func Init() error {
	mu.Lock()
	defer mu.Unlock()
	_ = os.MkdirAll(paths.Data(), 0o755)
	if err := loadUsersLocked(); err != nil {
		return err
	}
	_ = loadTokensLocked()
	if !hasAdminLocked() {
		if err := bootstrapAdminLocked(); err != nil {
			return err
		}
	}
	return nil
}

func hasAdminLocked() bool {
	for _, u := range users {
		if u.Role == RoleAdmin && u.Enabled {
			return true
		}
	}
	return false
}

func bootstrapAdminLocked() error {
	const pass = "admin"
	hash, err := bcrypt.GenerateFromPassword([]byte(pass), bcrypt.DefaultCost)
	if err != nil {
		return err
	}
	u := &User{
		ID:                 newID(),
		Username:           "admin",
		PassHash:           string(hash),
		Role:               RoleAdmin,
		Enabled:            true,
		MustChangePassword: true,
		CreatedAt:          time.Now().UTC(),
	}
	users[u.ID] = u
	byName[strings.ToLower(u.Username)] = u
	if err := saveUsersLocked(); err != nil {
		return err
	}
	msg := fmt.Sprintf(
		"username=admin\npassword=admin\ncreated=%s\nnote=请尽快修改默认密码\n",
		time.Now().UTC().Format(time.RFC3339),
	)
	_ = os.WriteFile(bootstrapPath(), []byte(msg), 0o600)
	log.Printf("auth: 已创建初始管理员 admin（默认密码 admin，请尽快修改），见 %s", bootstrapPath())
	return nil
}

func loadUsersLocked() error {
	users = map[string]*User{}
	byName = map[string]*User{}
	b, err := os.ReadFile(usersPath())
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	var f storeFile
	if err := json.Unmarshal(b, &f); err != nil {
		return err
	}
	for i := range f.Users {
		u := f.Users[i]
		cp := u
		users[cp.ID] = &cp
		byName[strings.ToLower(cp.Username)] = &cp
	}
	return nil
}

func saveUsersLocked() error {
	list := make([]User, 0, len(users))
	for _, u := range users {
		list = append(list, *u)
	}
	b, err := json.MarshalIndent(storeFile{Users: list}, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(usersPath(), b, 0o600)
}

func loadTokensLocked() error {
	tokens = map[string]*tokenRec{}
	b, err := os.ReadFile(tokensPath())
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	var f tokenFile
	if err := json.Unmarshal(b, &f); err != nil {
		return err
	}
	now := time.Now()
	for i := range f.Tokens {
		t := f.Tokens[i]
		if t.ExpiresAt.Before(now) {
			continue
		}
		cp := t
		tokens[cp.Token] = &cp
	}
	return nil
}

func saveTokensLocked() error {
	list := make([]tokenRec, 0, len(tokens))
	now := time.Now()
	for _, t := range tokens {
		if t.ExpiresAt.Before(now) {
			continue
		}
		list = append(list, *t)
	}
	b, err := json.MarshalIndent(tokenFile{Tokens: list}, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(tokensPath(), b, 0o600)
}

func newID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
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
	u := byName[strings.ToLower(username)]
	if u == nil || !u.Enabled {
		return "", User{}, fmt.Errorf("用户名或密码错误")
	}
	if bcrypt.CompareHashAndPassword([]byte(u.PassHash), []byte(password)) != nil {
		return "", User{}, fmt.Errorf("用户名或密码错误")
	}
	tok := newID() + newID()
	rec := &tokenRec{Token: tok, UserID: u.ID, ExpiresAt: time.Now().Add(tokenTTL)}
	tokens[tok] = rec
	_ = saveTokensLocked()
	return tok, *u, nil
}

// Register 开放注册（仅 AllowRegister）。
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
	if _, ok := byName[strings.ToLower(username)]; ok {
		return User{}, fmt.Errorf("用户名已存在")
	}
	u := &User{
		ID:        newID(),
		Username:  username,
		PassHash:  string(hash),
		Role:      RoleUser,
		Enabled:   true,
		CreatedAt: time.Now().UTC(),
	}
	users[u.ID] = u
	byName[strings.ToLower(username)] = u
	if err := saveUsersLocked(); err != nil {
		return User{}, err
	}
	return *u, nil
}

// Logout 作废 token。
func Logout(token string) {
	token = strings.TrimSpace(token)
	if token == "" {
		return
	}
	mu.Lock()
	defer mu.Unlock()
	delete(tokens, token)
	_ = saveTokensLocked()
}

// LookupToken 返回有效用户。
func LookupToken(token string) (*User, error) {
	token = strings.TrimSpace(token)
	if token == "" {
		return nil, fmt.Errorf("未登录")
	}
	mu.Lock()
	defer mu.Unlock()
	rec := tokens[token]
	if rec == nil || rec.ExpiresAt.Before(time.Now()) {
		if rec != nil {
			delete(tokens, token)
		}
		return nil, fmt.Errorf("登录已失效")
	}
	u := users[rec.UserID]
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
	out := make([]User, 0, len(users))
	for _, u := range users {
		out = append(out, *u)
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
	if _, ok := byName[strings.ToLower(username)]; ok {
		return User{}, fmt.Errorf("用户名已存在")
	}
	u := &User{
		ID:        newID(),
		Username:  username,
		PassHash:  string(hash),
		Role:      role,
		Enabled:   true,
		CreatedAt: time.Now().UTC(),
	}
	users[u.ID] = u
	byName[strings.ToLower(username)] = u
	if err := saveUsersLocked(); err != nil {
		return User{}, err
	}
	return *u, nil
}

// SetEnabled 启用/禁用。
func SetEnabled(userID string, enabled bool) error {
	mu.Lock()
	defer mu.Unlock()
	u := users[userID]
	if u == nil {
		return fmt.Errorf("用户不存在")
	}
	if u.Role == RoleAdmin && !enabled && countAdminsLocked() <= 1 {
		return fmt.Errorf("不能禁用唯一管理员")
	}
	u.Enabled = enabled
	return saveUsersLocked()
}

func countAdminsLocked() int {
	n := 0
	for _, u := range users {
		if u.Role == RoleAdmin && u.Enabled {
			n++
		}
	}
	return n
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
	u := users[userID]
	if u == nil {
		return fmt.Errorf("用户不存在")
	}
	u.PassHash = string(hash)
	u.MustChangePassword = false
	return saveUsersLocked()
}

// ChangePassword 登录用户修改自己的密码（需旧密码）。
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
	u := users[userID]
	if u == nil || !u.Enabled {
		return fmt.Errorf("用户不可用")
	}
	if bcrypt.CompareHashAndPassword([]byte(u.PassHash), []byte(oldPassword)) != nil {
		return fmt.Errorf("旧密码错误")
	}
	u.PassHash = string(hash)
	u.MustChangePassword = false
	return saveUsersLocked()
}

// DeleteUser 删除用户（不可删唯一管理员）。
func DeleteUser(userID string) error {
	mu.Lock()
	defer mu.Unlock()
	u := users[userID]
	if u == nil {
		return fmt.Errorf("用户不存在")
	}
	if u.Role == RoleAdmin && countAdminsLocked() <= 1 {
		return fmt.Errorf("不能删除唯一管理员")
	}
	delete(byName, strings.ToLower(u.Username))
	delete(users, userID)
	for tok, rec := range tokens {
		if rec.UserID == userID {
			delete(tokens, tok)
		}
	}
	_ = saveTokensLocked()
	return saveUsersLocked()
}

// GetUser 按 ID。
func GetUser(id string) *User {
	mu.Lock()
	defer mu.Unlock()
	u := users[id]
	if u == nil {
		return nil
	}
	cp := *u
	return &cp
}

// BearerFromRequest 解析 Authorization: Bearer。
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
