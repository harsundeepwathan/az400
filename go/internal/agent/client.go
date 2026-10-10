package agent

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

// Client talks to the ingest API.
type Client struct {
	base string
	http *http.Client
	auth func() string
}

// ErrUnauthorized means the server rejected the agent identity (revoked or rotated).
var ErrUnauthorized = errors.New("agent credential rejected by server")

// PermanentError is a 4xx rejection that retrying will not fix (e.g. a batch that fails
// validation). The sender drops such a batch instead of blocking the queue.
type PermanentError struct {
	Status int
	Body   string
}

func (e *PermanentError) Error() string {
	return fmt.Sprintf("server rejected request (%d): %s", e.Status, e.Body)
}

// RetryAfterError carries a server-requested delay.
type RetryAfterError struct{ After time.Duration }

func (e *RetryAfterError) Error() string {
	return fmt.Sprintf("server asked to retry after %s", e.After)
}

// NewClient builds a client. TLS 1.2+ is required; a custom CA can be supplied for
// private PKI deployments.
func NewClient(cfg *Config, auth func() string) (*Client, error) {
	tlsCfg := &tls.Config{MinVersion: tls.VersionTLS12}
	if cfg.CAFile != "" {
		pem, err := os.ReadFile(cfg.CAFile)
		if err != nil {
			return nil, err
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pem) {
			return nil, errors.New("ca_file contains no certificates")
		}
		tlsCfg.RootCAs = pool
	}
	tr := &http.Transport{
		Proxy:               http.ProxyFromEnvironment, // outbound proxies are common in enterprise networks
		TLSClientConfig:     tlsCfg,
		TLSHandshakeTimeout: 10 * time.Second,
		MaxIdleConns:        2,
		IdleConnTimeout:     90 * time.Second,
	}
	return &Client{base: strings.TrimRight(cfg.ServerURL, "/"), http: &http.Client{Transport: tr, Timeout: 30 * time.Second}, auth: auth}, nil
}

// Do sends a JSON request and decodes a JSON response.
func (c *Client) Do(ctx context.Context, method, path string, in, out any) error {
	var body io.Reader
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			return err
		}
		body = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.base+path, body)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "skywatch-agent/"+Version)
	if c.auth != nil {
		if a := c.auth(); a != "" {
			req.Header.Set("Authorization", "Bearer "+a)
		}
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	switch {
	case resp.StatusCode == http.StatusUnauthorized:
		return ErrUnauthorized
	case resp.StatusCode == http.StatusTooManyRequests || resp.StatusCode == http.StatusServiceUnavailable:
		after := 30 * time.Second
		if s, err := strconv.Atoi(resp.Header.Get("Retry-After")); err == nil && s > 0 {
			after = time.Duration(s) * time.Second
		}
		return &RetryAfterError{After: after}
	case resp.StatusCode >= 400 && resp.StatusCode < 500:
		return &PermanentError{Status: resp.StatusCode, Body: strings.TrimSpace(string(data))}
	case resp.StatusCode >= 400:
		return fmt.Errorf("server returned %d: %s", resp.StatusCode, strings.TrimSpace(string(data)))
	}
	if out != nil {
		return json.Unmarshal(data, out)
	}
	return nil
}
