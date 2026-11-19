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
	// 令牌在使用中滑动续期：距上次续期超过一天就把有效期重新拉满 tokenTTL。
	tokenRenewAfter = 24 * time.Hour
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
	GroupID            string    `json:"groupId"`
	Status             string    `json:"status"`
	Note               string    `json:"note,omitempty"`
	ExpiresAt          int64     `json:"expiresAt,omitempty"`
}

// Public 返回不含密码哈希的视图。
func (u User) Public() map[string]any {
	gid := u.GroupID
	if gid == "" {
		gid = database.DefaultGroupID
	}
	st := u.Status
	if st == "" {
		st = "active"
	}
	return map[string]any{
		"id":                 u.ID,
		"username":           u.Username,
		"role":               u.Role,
		"enabled":            u.Enabled,
		"mustChangePassword": u.MustChangePassword,
		"createdAt":          u.CreatedAt.UTC().Format(time.RFC3339),
		"groupId":            gid,
		"status":             st,
		"note":               u.Note,
		"expiresAt":          u.ExpiresAt,
	}
}

var (
	mu    sync.Mutex
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
	gid := u.GroupID
	if gid == "" {
		gid = database.DefaultGroupID
	}
	st := u.Status
	if st == "" {
		st = "active"
	}
	return &User{
		ID:                 u.ID,
		Username:           u.Username,
		PassHash:           u.PassHash,
		Role:               u.Role,
		Enabled:            u.Enabled,
		MustChangePassword: u.MustChangePassword,
		CreatedAt:          u.CreatedAt,
		GroupID:            gid,
		Status:             st,
		Note:               u.Note,
		ExpiresAt:          u.ExpiresAt,
	}
}

func toRow(u User) database.AuthUser {
	gid := u.GroupID
	if gid == "" {
		gid = database.DefaultGroupID
	}
	st := u.Status
	if st == "" {
		st = "active"
	}
	return database.AuthUser{
		ID:                 u.ID,
		Username:           u.Username,
		PassHash:           u.PassHash,
		Role:               u.Role,
		Enabled:            u.Enabled,
		MustChangePassword: u.MustChangePassword,
		CreatedAt:          u.CreatedAt,
		GroupID:            gid,
		Status:             st,
		Note:               u.Note,
		ExpiresAt:          u.ExpiresAt,
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
func RemoteAuthEnabled() bool { return settings.Bool(settings.RemoteAuth, false) }

// AllowRegister 是否开放注册。
func AllowRegister() bool { return settings.Bool(settings.AllowRegister, false) }

// RequireApproval 自助注册是否需管理员审批后才能登录。
func RequireApproval() bool { return settings.Bool(settings.RequireApproval, false) }

// SetRemoteAuth / SetAllowRegister / SetRequireApproval 供管理页写入。
func SetRemoteAuth(on bool) error {
	return setBoolSetting(settings.RemoteAuth, on)
}

func SetAllowRegister(on bool) error {
	return setBoolSetting(settings.AllowRegister, on)
}

func SetRequireApproval(on bool) error {
	return setBoolSetting(settings.RequireApproval, on)
}

func setBoolSetting(t settings.Type, on bool) error {
	if on {
		settings.Set(t, "true")
	} else {
		settings.Set(t, "false")
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
	if u.Status == "pending" {
		return "", User{}, fmt.Errorf("账号待审批")
	}
	if u.Status == "disabled" {
		return "", User{}, fmt.Errorf("账号已禁用")
	}
	if u.ExpiresAt > 0 && time.Now().UnixMilli() > u.ExpiresAt {
		return "", User{}, fmt.Errorf("账号已到期")
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

// Register 开放注册；inviteCode 非空时消费邀请码并入对应分组。
func Register(username, password string) (User, error) {
	return RegisterWithInvite(username, password, "")
}

// RegisterWithInvite 注册并可绑定邀请码。
func RegisterWithInvite(username, password, inviteCode string) (User, error) {
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
	inviteCode = strings.TrimSpace(inviteCode)
	if settings.Bool(settings.RequireInvite, false) && inviteCode == "" {
		return User{}, fmt.Errorf("需要邀请码")
	}
	u, err := insertUser(username, password, RoleUser)
	if err != nil {
		return User{}, err
	}
	db, err := requireDB()
	if err != nil {
		return u, nil
	}
	if inviteCode != "" {
		gid, cerr := db.ConsumeInvite(inviteCode)
		if cerr != nil {
			_ = db.DeleteAuthUser(u.ID)
			return User{}, cerr
		}
		_ = SetUserGroup(u.ID, gid)
		if nu := GetUser(u.ID); nu != nil {
			u = *nu
		}
	}
	if RequireApproval() {
		u.Status = "pending"
		u.Enabled = false
		_ = db.UpsertAuthUser(toRow(u))
		_ = db.DeleteAuthTokensForUser(u.ID)
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

// LookupToken 返回有效用户，并为常用的令牌续期（不常用满 tokenTTL 才失效）。
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
	if u.Status == "pending" {
		return nil, fmt.Errorf("账号待审批")
	}
	if u.Status == "disabled" {
		return nil, fmt.Errorf("账号已禁用")
	}
	if u.ExpiresAt > 0 && time.Now().UnixMilli() > u.ExpiresAt {
		return nil, fmt.Errorf("账号已到期")
	}
	if time.Until(rec.ExpiresAt) < tokenTTL-tokenRenewAfter {
		rec.ExpiresAt = time.Now().Add(tokenTTL)
		_ = db.InsertAuthToken(*rec)
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
	return insertUser(username, password, role)
}

func insertUser(username, password, role string) (User, error) {
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
	defaultGID := database.DefaultGroupID
	if dg := strings.TrimSpace(settings.Get(settings.Type("defaultGroupId"))); dg != "" {
		if g, _ := db.GetAuthGroup(dg); g != nil {
			defaultGID = dg
		}
	}
	u := User{
		ID:        newID(),
		Username:  username,
		PassHash:  string(hash),
		Role:      role,
		Enabled:   true,
		CreatedAt: time.Now().UTC(),
		GroupID:   defaultGID,
		Status:    "active",
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

// ResetPassword 管理员重置密码；该用户所有设备需重新登录。
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
	if err := db.UpsertAuthUser(toRow(*u)); err != nil {
		return err
	}
	return db.DeleteAuthTokensForUser(userID)
}

// ChangePassword 登录用户修改自己的密码；除 keepToken（当前设备）外的登录全部失效。
func ChangePassword(userID, keepToken, oldPassword, newPassword string) error {
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
	if err := db.UpsertAuthUser(toRow(*u)); err != nil {
		return err
	}
	return db.DeleteAuthTokensForUserExcept(userID, strings.TrimSpace(keepToken))
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

// SetUserRole 设置用户角色（user|admin）；降级唯一管理员会被拒绝。
func SetUserRole(userID, role string) error {
	role = strings.TrimSpace(strings.ToLower(role))
	if role != RoleAdmin && role != RoleUser {
		return fmt.Errorf("角色无效")
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
	if u.Role == RoleAdmin && role != RoleAdmin {
		n, err := db.CountAuthAdmins()
		if err != nil {
			return err
		}
		if n <= 1 {
			return fmt.Errorf("不能取消唯一管理员")
		}
	}
	u.Role = role
	return db.UpsertAuthUser(toRow(*u))
}

// SetUserGroup 指定用户唯一分组。
func SetUserGroup(userID, groupID string) error {
	groupID = strings.TrimSpace(groupID)
	if groupID == "" {
		groupID = database.DefaultGroupID
	}
	mu.Lock()
	defer mu.Unlock()
	db, err := requireDB()
	if err != nil {
		return err
	}
	if g, err := db.GetAuthGroup(groupID); err != nil {
		return err
	} else if g == nil {
		return fmt.Errorf("分组不存在")
	}
	row, err := db.GetAuthUser(userID)
	if err != nil {
		return err
	}
	u := fromRow(row)
	if u == nil {
		return fmt.Errorf("用户不存在")
	}
	u.GroupID = groupID
	return db.UpsertAuthUser(toRow(*u))
}

// ForceLogout 撤销用户全部 token。
func ForceLogout(userID string) error {
	mu.Lock()
	defer mu.Unlock()
	db, err := requireDB()
	if err != nil {
		return err
	}
	return db.DeleteAuthTokensForUser(userID)
}
