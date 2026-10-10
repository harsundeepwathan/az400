// Package testdb creates throwaway migrated PostgreSQL databases for integration tests.
// Tests are skipped when SKYWATCH_TEST_ADMIN_URL is unset and the default local
// server is unreachable.
package testdb

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/harsundeepwathan/az400/go/internal/db"
)

// New creates a database, migrates it and returns a pool connected as a superuser.
func New(t *testing.T) *pgxpool.Pool {
	t.Helper()
	admin := os.Getenv("SKYWATCH_TEST_ADMIN_URL")
	if admin == "" {
		admin = "postgres://postgres:postgres@127.0.0.1:5432/postgres"
	}
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, admin)
	if err != nil {
		t.Skipf("integration database unavailable: %v", err)
	}
	defer conn.Close(ctx)
	b := make([]byte, 4)
	_, _ = rand.Read(b)
	name := "skywatch_test_" + hex.EncodeToString(b)
	if _, err := conn.Exec(ctx, "CREATE DATABASE "+name); err != nil {
		t.Fatal(err)
	}
	u, _ := url.Parse(admin)
	u.Path = "/" + name
	dsn := u.String()
	_, file, _, _ := runtime.Caller(0)
	migrations := filepath.Join(filepath.Dir(file), "..", "..", "..", "db", "migrations")
	if _, err := db.Migrate(ctx, dsn, migrations); err != nil {
		t.Fatal(err)
	}
	pool, err := db.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		pool.Close()
		c, err := pgx.Connect(context.Background(), admin)
		if err == nil {
			_, _ = c.Exec(context.Background(), "DROP DATABASE IF EXISTS "+name+" WITH (FORCE)")
			c.Close(context.Background())
		}
	})
	return pool
}
