package notify

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"github.com/harsundeepwathan/az400/go/internal/secrets"
	"github.com/harsundeepwathan/az400/go/internal/testdb"
)

func TestDrainSendsRetriesAndFails(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	kr, _ := secrets.NewLocalKeyring("v1:AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")
	var hits atomic.Int32
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if hits.Add(1) == 1 {
			w.WriteHeader(503) // first attempt fails transiently
		}
	}))
	defer srv.Close()
	var org string
	_ = pool.QueryRow(ctx, `INSERT INTO organizations(name, slug) VALUES ('n','notify-org') RETURNING id`).Scan(&org)
	chID := "11111111-1111-1111-1111-111111111111"
	secret, _ := json.Marshal(map[string]string{"url": srv.URL + "/hook"})
	blob, _ := secrets.Seal(ctx, kr, secret, secrets.ChannelAAD(org, chID))
	if _, err := pool.Exec(ctx, `INSERT INTO notification_channels(id, org_id, kind, name, secret_ciphertext) VALUES ($1,$2,'webhook','hook',$3)`, chID, org, blob); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO notification_deliveries(org_id, channel_id, event, dedup_key, payload) VALUES ($1,$2,'opened','k1','{"event":"opened","incident":{"title":"x"}}')`, org, chID); err != nil {
		t.Fatal(err)
	}
	n := New(pool, kr, Config{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	n.SetHTTPClient(srv.Client())
	if _, err := n.Drain(ctx, 10); err != nil {
		t.Fatal(err)
	}
	var status string
	var attempts int
	_ = pool.QueryRow(ctx, `SELECT status, attempts FROM notification_deliveries WHERE dedup_key='k1'`).Scan(&status, &attempts)
	if status != "pending" || attempts != 1 {
		t.Fatalf("transient failure should schedule a retry: %s/%d", status, attempts)
	}
	_, _ = pool.Exec(ctx, `UPDATE notification_deliveries SET next_attempt_at = now()`)
	if _, err := n.Drain(ctx, 10); err != nil {
		t.Fatal(err)
	}
	_ = pool.QueryRow(ctx, `SELECT status, attempts FROM notification_deliveries WHERE dedup_key='k1'`).Scan(&status, &attempts)
	if status != "sent" || attempts != 2 {
		t.Fatalf("retry should succeed: %s/%d", status, attempts)
	}
	// A channel secret that does not decrypt (wrong tenant AAD) cannot be sent.
	if _, err := pool.Exec(ctx, `INSERT INTO notification_deliveries(org_id, channel_id, event, dedup_key, payload) VALUES ($1,$2,'opened','k2','{"event":"opened","incident":{}}')`, org, chID); err != nil {
		t.Fatal(err)
	}
	if err := n.SendTest(ctx, "00000000-0000-0000-0000-000000000000", chID); err == nil {
		t.Fatal("test send for another org must fail")
	}
}
