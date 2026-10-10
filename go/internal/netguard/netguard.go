// Package netguard protects outbound requests made on behalf of tenants (synthetic
// probes, webhooks) against SSRF. The resolved IP — not the hostname — is checked at
// dial time, which also defeats DNS rebinding between check and connect.
package netguard

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"syscall"
	"time"
)

// ErrBlocked is returned when a destination is not allowed.
var ErrBlocked = errors.New("destination address not allowed")

var blockedPrefixes = mustPrefixes(
	"0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
	"192.0.0.0/24", "192.0.2.0/24", "192.88.99.0/24", "192.168.0.0/16", "198.18.0.0/15", "198.51.100.0/24",
	"203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4", "255.255.255.255/32",
	"::/128", "::1/128", "::ffff:0:0/96", "64:ff9b::/96", "100::/64", "2001::/23", "2001:db8::/32",
	"fc00::/7", "fe80::/10", "ff00::/8",
	// Cloud metadata endpoints not covered above (Alibaba Cloud uses 100.100.100.200,
	// inside 100.64.0.0/10; Azure/AWS/GCP/DO use 169.254.169.254).
)

func mustPrefixes(ss ...string) []netip.Prefix {
	out := make([]netip.Prefix, len(ss))
	for i, s := range ss {
		out[i] = netip.MustParsePrefix(s)
	}
	return out
}

// Policy controls which destinations are reachable.
type Policy struct {
	// AllowPrivate permits private/loopback ranges. Only private probes deployed inside
	// a customer network set this; the shared public probe never does.
	AllowPrivate bool
	// AllowedPorts restricts destination ports; empty allows any port.
	AllowedPorts map[int]bool
}

// Allowed checks an address against the policy.
func (p Policy) Allowed(addr netip.Addr, port int) error {
	if len(p.AllowedPorts) > 0 && !p.AllowedPorts[port] {
		return fmt.Errorf("%w: port %d", ErrBlocked, port)
	}
	addr = addr.Unmap()
	if !addr.IsValid() {
		return ErrBlocked
	}
	if p.AllowPrivate {
		// Even private probes never reach cloud instance metadata services.
		if addr == netip.MustParseAddr("169.254.169.254") || addr == netip.MustParseAddr("100.100.100.200") ||
			addr == netip.MustParseAddr("fd00:ec2::254") {
			return fmt.Errorf("%w: metadata service", ErrBlocked)
		}
		return nil
	}
	for _, pf := range blockedPrefixes {
		if pf.Contains(addr) {
			return fmt.Errorf("%w: %s is in %s", ErrBlocked, addr, pf)
		}
	}
	return nil
}

// Dialer returns a net.Dialer whose Control hook enforces the policy on the actual
// socket address being connected.
func (p Policy) Dialer(timeout time.Duration) *net.Dialer {
	return &net.Dialer{
		Timeout: timeout,
		Control: func(network, address string, _ syscall.RawConn) error {
			ap, err := netip.ParseAddrPort(address)
			if err != nil {
				return ErrBlocked
			}
			return p.Allowed(ap.Addr(), int(ap.Port()))
		},
	}
}

// HTTPClient returns an HTTP client that enforces the policy, does not use proxies from
// the environment, and limits redirects (each redirect target is re-checked at dial).
func (p Policy) HTTPClient(timeout time.Duration, followRedirects bool) *http.Client {
	d := p.Dialer(timeout)
	tr := &http.Transport{
		Proxy:                 nil,
		DialContext:           d.DialContext,
		TLSHandshakeTimeout:   timeout,
		ResponseHeaderTimeout: timeout,
		MaxIdleConns:          50,
		IdleConnTimeout:       30 * time.Second,
		DisableKeepAlives:     true,
	}
	c := &http.Client{Transport: tr, Timeout: timeout}
	c.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if !followRedirects {
			return http.ErrUseLastResponse
		}
		if len(via) >= 5 {
			return errors.New("too many redirects")
		}
		return nil
	}
	return c
}

// Resolve resolves a host and returns the first allowed address.
func (p Policy) Resolve(ctx context.Context, r *net.Resolver, host string, port int) (netip.Addr, error) {
	addrs, err := r.LookupNetIP(ctx, "ip", host)
	if err != nil {
		return netip.Addr{}, err
	}
	var lastErr error = ErrBlocked
	for _, a := range addrs {
		if err := p.Allowed(a, port); err == nil {
			return a, nil
		} else {
			lastErr = err
		}
	}
	return netip.Addr{}, lastErr
}
