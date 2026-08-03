package server

import (
	"context"

	"github.com/bobo/KOTV/internal/auth"
)

type ctxKey int

const authUserKey ctxKey = 1

func withAuthUser(ctx context.Context, u *auth.User) context.Context {
	return context.WithValue(ctx, authUserKey, u)
}

func authUserFrom(ctx context.Context) *auth.User {
	u, _ := ctx.Value(authUserKey).(*auth.User)
	return u
}
