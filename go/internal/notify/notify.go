// Package notify delivers queued incident notifications (transactional outbox in
// notification_deliveries) to Email, Slack, Microsoft Teams, generic webhooks and
// Telegram, with retries and exponential backoff.
package notify

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/smtp"
	"net/url"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/harsundeepwathan/az400/go/internal/netguard"
	"github.com/harsundeepwathan/az400/go/internal/secrets"
	"github.com/harsundeepwathan/az400/go/internal/selfmon"
)

// Config for the notifier.
type Config struct {
	PublicURL   string // base URL of the web UI, used for incident links
	SMTPAddr    string // host:port
	SMTPFrom    string
	SMTPUser    string
	SMTPPass    string
	MaxAttempts int
	// AllowPrivateTargets permits webhooks to private addresses (self-hosted installs
	// posting to an internal endpoint). Off by default.
	AllowPrivateTargets bool
}

// Notifier drains the outbox.
type Notifier struct {
	pool *pgxpool.Pool
	keys secrets.KeyProvider
	cfg  Config
	log  *slog.Logger
	http *http.Client
	// Senders can be replaced in tests.
	SendMail func(addr string, a smtp.Auth, from string, to []string, msg []byte) error
}

// New creates a notifier.
func New(pool *pgxpool.Pool, keys secrets.KeyProvider, cfg Config, log *slog.Logger) *Notifier {
	if cfg.MaxAttempts <= 0 {
		cfg.MaxAttempts = 8
	}
	pol := netguard.Policy{AllowPrivate: cfg.AllowPrivateTargets}
	return &Notifier{pool: pool, keys: keys, cfg: cfg, log: log, http: pol.HTTPClient(10*time.Second, false), SendMail: smtp.SendMail}
}

// SetHTTPClient overrides the HTTP client (tests).
func (n *Notifier) SetHTTPClient(c *http.Client) { n.http = c }

// Run polls the outbox until ctx is cancelled.
func (n *Notifier) Run(ctx context.Context) error {
	t := time.NewTicker(3 * time.Second)
	defer t.Stop()
	for {
		if _, err := n.Drain(ctx, 50); err != nil && ctx.Err() == nil {
			n.log.Error("notifier drain", "err", err)
		}
		select {
		case <-ctx.Done():
			return nil
		case <-t.C:
		}
	}
}

type delivery struct {
	ID        int64
	OrgID     string
	ChannelID string
	Kind      string
	Name      string
	Attempts  int
	Payload   map[string]any
	Config    map[string]any
	Secret    map[string]string
}

// Drain sends up to limit due deliveries. Returns the number processed.
func (n *Notifier) Drain(ctx context.Context, limit int) (int, error) {
	tx, err := n.pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	rows, err := tx.Query(ctx, `SELECT d.id, d.org_id, d.channel_id, c.kind, c.name, d.attempts, d.payload, c.config, c.secret_ciphertext
		FROM notification_deliveries d JOIN notification_channels c ON c.id = d.channel_id
		WHERE d.status='pending' AND d.next_attempt_at <= now()
		ORDER BY d.next_attempt_at FOR UPDATE OF d SKIP LOCKED LIMIT $1`, limit)
	if err != nil {
		return 0, err
	}
	var batch []delivery
	for rows.Next() {
		var d delivery
		var payload, cfg, secret []byte
		if err := rows.Scan(&d.ID, &d.OrgID, &d.ChannelID, &d.Kind, &d.Name, &d.Attempts, &payload, &cfg, &secret); err != nil {
			rows.Close()
			return 0, err
		}
		_ = json.Unmarshal(payload, &d.Payload)
		_ = json.Unmarshal(cfg, &d.Config)
		d.Secret = map[string]string{}
		if len(secret) > 0 {
			pt, err := secrets.Open(ctx, n.keys, secret, secrets.ChannelAAD(d.OrgID, d.ChannelID))
			if err == nil {
				_ = json.Unmarshal(pt, &d.Secret)
			}
		}
		batch = append(batch, d)
	}
	rows.Close()
	for _, d := range batch {
		sendCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
		err := n.Send(sendCtx, d.Kind, d.Config, d.Secret, d.Payload)
		cancel()
		attempts := d.Attempts + 1
		if err == nil {
			selfmon.NotificationsSent.WithLabelValues(d.Kind, "sent").Inc()
			_, err = tx.Exec(ctx, `UPDATE notification_deliveries SET status='sent', attempts=$2, sent_at=now(), last_error=NULL WHERE id=$1`, d.ID, attempts)
			if err != nil {
				return 0, err
			}
			continue
		}
		n.log.Warn("notification failed", "channel", d.Name, "kind", d.Kind, "attempt", attempts, "err", err)
		status := "pending"
		if attempts >= n.cfg.MaxAttempts || errors.Is(err, errPermanent) {
			status = "failed"
		}
		selfmon.NotificationsSent.WithLabelValues(d.Kind, map[bool]string{true: "failed", false: "retry"}[status == "failed"]).Inc()
		backoff := time.Duration(1<<min(attempts, 10)) * 15 * time.Second
		if _, err2 := tx.Exec(ctx, `UPDATE notification_deliveries SET status=$2, attempts=$3, last_error=$4, next_attempt_at=now() + $5::interval WHERE id=$1`,
			d.ID, status, attempts, truncate(err.Error(), 500), fmt.Sprintf("%d seconds", int(backoff.Seconds()))); err2 != nil {
			return 0, err2
		}
	}
	return len(batch), tx.Commit(ctx)
}

var errPermanent = errors.New("permanent delivery failure")

// Send renders and sends one notification.
func (n *Notifier) Send(ctx context.Context, kind string, cfg map[string]any, secret map[string]string, p map[string]any) error {
	msg := render(p, n.cfg.PublicURL)
	switch kind {
	case "slack":
		return n.postJSON(ctx, secret["webhook_url"], slackBody(msg), nil)
	case "teams":
		return n.postJSON(ctx, secret["webhook_url"], teamsBody(msg), nil)
	case "webhook":
		body, _ := json.Marshal(p)
		headers := map[string]string{"X-Skywatch-Event": msg.Event}
		if s := secret["signing_secret"]; s != "" {
			ts := fmt.Sprint(time.Now().Unix())
			mac := hmac.New(sha256.New, []byte(s))
			mac.Write([]byte(ts + "." + string(body)))
			headers["X-Skywatch-Timestamp"] = ts
			headers["X-Skywatch-Signature"] = "v1=" + hex.EncodeToString(mac.Sum(nil))
		}
		return n.post(ctx, secret["url"], "application/json", body, headers)
	case "telegram":
		chatID, _ := cfg["chat_id"].(string)
		token := secret["bot_token"]
		if token == "" || chatID == "" {
			return fmt.Errorf("%w: telegram bot_token and chat_id required", errPermanent)
		}
		body, _ := json.Marshal(map[string]any{"chat_id": chatID, "text": msg.Text(), "disable_web_page_preview": true})
		return n.post(ctx, "https://api.telegram.org/bot"+url.PathEscape(token)+"/sendMessage", "application/json", body, nil)
	case "email":
		return n.sendEmail(cfg, msg)
	}
	return fmt.Errorf("%w: unknown channel kind %q", errPermanent, kind)
}

func (n *Notifier) postJSON(ctx context.Context, target string, v any, headers map[string]string) error {
	b, _ := json.Marshal(v)
	return n.post(ctx, target, "application/json", b, headers)
}

func (n *Notifier) post(ctx context.Context, target, ctype string, body []byte, headers map[string]string) error {
	u, err := url.Parse(target)
	if err != nil || u.Scheme != "https" || u.Host == "" {
		return fmt.Errorf("%w: target must be an https URL", errPermanent)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, target, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", ctype)
	req.Header.Set("User-Agent", "Skywatch-Notifier/1")
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := n.http.Do(req)
	if err != nil {
		if errors.Is(err, netguard.ErrBlocked) {
			return fmt.Errorf("%w: %v", errPermanent, err)
		}
		return err
	}
	defer resp.Body.Close()
	switch {
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		return nil
	case resp.StatusCode == 429 || resp.StatusCode >= 500:
		return fmt.Errorf("HTTP %d (will retry)", resp.StatusCode)
	default:
		return fmt.Errorf("%w: HTTP %d", errPermanent, resp.StatusCode)
	}
}

func (n *Notifier) sendEmail(cfg map[string]any, m message) error {
	if n.cfg.SMTPAddr == "" {
		return fmt.Errorf("%w: SMTP is not configured on this deployment", errPermanent)
	}
	var to []string
	if list, ok := cfg["to"].([]any); ok {
		for _, x := range list {
			if s, ok := x.(string); ok && strings.Contains(s, "@") && !strings.ContainsAny(s, "\r\n") {
				to = append(to, s)
			}
		}
	}
	if len(to) == 0 {
		return fmt.Errorf("%w: no recipients", errPermanent)
	}
	var auth smtp.Auth
	if n.cfg.SMTPUser != "" {
		host := n.cfg.SMTPAddr
		if i := strings.LastIndex(host, ":"); i > 0 {
			host = host[:i]
		}
		auth = smtp.PlainAuth("", n.cfg.SMTPUser, n.cfg.SMTPPass, host)
	}
	subject := strings.NewReplacer("\r", " ", "\n", " ").Replace(m.Subject())
	body := fmt.Sprintf("From: %s\r\nTo: %s\r\nSubject: %s\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n%s\r\n",
		n.cfg.SMTPFrom, strings.Join(to, ", "), subject, m.Text())
	return n.SendMail(n.cfg.SMTPAddr, auth, n.cfg.SMTPFrom, to, []byte(body))
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}
