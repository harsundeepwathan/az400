package netguard

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"testing"
	"time"
)

func TestPublicPolicyBlocksInternalRanges(t *testing.T) {
	p := Policy{}
	for _, a := range []string{"127.0.0.1", "10.1.2.3", "172.20.0.1", "192.168.1.1", "169.254.169.254",
		"100.100.100.200", "::1", "fd12::1", "fe80::1", "::ffff:127.0.0.1", "0.0.0.0"} {
		if err := p.Allowed(netip.MustParseAddr(a), 443); !errors.Is(err, ErrBlocked) {
			t.Errorf("%s should be blocked", a)
		}
	}
	for _, a := range []string{"8.8.8.8", "1.1.1.1", "2606:4700:4700::1111"} {
		if err := p.Allowed(netip.MustParseAddr(a), 443); err != nil {
			t.Errorf("%s should be allowed: %v", a, err)
		}
	}
}

func TestPrivatePolicyStillBlocksMetadata(t *testing.T) {
	p := Policy{AllowPrivate: true}
	if p.Allowed(netip.MustParseAddr("10.0.0.5"), 80) != nil {
		t.Error("private probe should reach RFC1918")
	}
	if p.Allowed(netip.MustParseAddr("169.254.169.254"), 80) == nil {
		t.Error("metadata must stay blocked")
	}
}

func TestHTTPClientBlocksLoopbackAtDial(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer srv.Close()
	c := Policy{}.HTTPClient(2*time.Second, true)
	if _, err := c.Get(srv.URL); err == nil || !errors.Is(err, ErrBlocked) {
		t.Fatalf("expected dial to be blocked, got %v", err)
	}
	ok := Policy{AllowPrivate: true}.HTTPClient(2*time.Second, true)
	if _, err := ok.Get(srv.URL); err != nil {
		t.Fatalf("private policy should allow loopback: %v", err)
	}
}

func TestPortAllowList(t *testing.T) {
	p := Policy{AllowedPorts: map[int]bool{443: true}}
	if p.Allowed(netip.MustParseAddr("8.8.8.8"), 22) == nil {
		t.Error("port 22 should be blocked")
	}
}
