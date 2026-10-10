package probe

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/harsundeepwathan/az400/go/internal/netguard"
)

func TestHTTPCheck(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/down" {
			w.WriteHeader(503)
			return
		}
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	}))
	defer srv.Close()
	r := &Runner{Policy: netguard.Policy{AllowPrivate: true}}
	ok := r.Run(context.Background(), Check{Kind: "http", Target: srv.URL + "/health", Config: Config{BodyContains: `"ok"`}})
	if !ok.OK || ok.StatusCode != 200 {
		t.Fatalf("expected ok: %+v", ok)
	}
	bad := r.Run(context.Background(), Check{Kind: "http", Target: srv.URL + "/down"})
	if bad.OK || bad.StatusCode != 503 {
		t.Fatalf("expected failure: %+v", bad)
	}
	body := r.Run(context.Background(), Check{Kind: "http", Target: srv.URL, Config: Config{BodyContains: "nope"}})
	if body.OK {
		t.Fatal("body assertion should fail")
	}
}

func TestPublicProbeRefusesPrivateTargets(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer srv.Close()
	r := &Runner{Policy: netguard.Policy{}}
	res := r.Run(context.Background(), Check{Kind: "http", Target: srv.URL})
	if res.OK || !strings.Contains(res.Error, "private probe") {
		t.Fatalf("public probe must refuse loopback: %+v", res)
	}
	res = r.Run(context.Background(), Check{Kind: "http", Target: "http://169.254.169.254/metadata/instance"})
	if res.OK || !strings.Contains(res.Error, "blocked") {
		t.Fatalf("metadata must be blocked: %+v", res)
	}
}

func TestTCPCheck(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			c.Close()
		}
	}()
	r := &Runner{Policy: netguard.Policy{AllowPrivate: true}}
	if res := r.Run(context.Background(), Check{Kind: "tcp", Target: ln.Addr().String()}); !res.OK {
		t.Fatalf("tcp ok expected: %+v", res)
	}
	addr := ln.Addr().String()
	ln.Close()
	if res := r.Run(context.Background(), Check{Kind: "tcp", Target: addr}); res.OK || res.Error != "connection refused" {
		t.Fatalf("expected refused: %+v", res)
	}
}

func TestTLSCheckReportsValidationFailure(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer srv.Close()
	r := &Runner{Policy: netguard.Policy{AllowPrivate: true}}
	res := r.Run(context.Background(), Check{Kind: "tls", Target: strings.TrimPrefix(srv.URL, "https://")})
	if res.OK || !strings.Contains(res.Error, "certificate validation failed") || res.DaysToExp == nil {
		t.Fatalf("self-signed cert must fail validation but report expiry: %+v", res)
	}
}

func TestICMPUnavailableIsExplicit(t *testing.T) {
	r := &Runner{}
	if res := r.Run(context.Background(), Check{Kind: "icmp", Target: "example.com"}); res.OK || !strings.Contains(res.Error, "not available") {
		t.Fatalf("%+v", res)
	}
}
