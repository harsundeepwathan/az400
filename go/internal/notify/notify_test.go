package notify

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/smtp"
	"strings"
	"testing"
)

func samplePayload(event string) map[string]any {
	return map[string]any{"event": event, "incident": map[string]any{
		"id": "inc-1", "number": float64(42), "title": "web-01: CPU high", "severity": "critical", "status": "open",
		"trigger_summary": "CPU high on web-01: 97.3% (threshold > 95.0%)", "first_detected_at": "2026-10-10T10:00:00Z",
		"resource": map[string]any{"name": "web-01", "provider": "azure", "region": "westeurope"},
	}}
}

func TestWebhookIsSignedAndSlackTeamsRender(t *testing.T) {
	var got = map[string]*http.Request{}
	var bodies = map[string][]byte{}
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		got[r.URL.Path] = r
		bodies[r.URL.Path] = b
	}))
	defer srv.Close()
	n := &Notifier{cfg: Config{PublicURL: "https://skywatch.example"}}
	n.SetHTTPClient(srv.Client())
	ctx := context.Background()

	if err := n.Send(ctx, "webhook", nil, map[string]string{"url": srv.URL + "/hook", "signing_secret": "k"}, samplePayload("opened")); err != nil {
		t.Fatal(err)
	}
	r := got["/hook"]
	mac := hmac.New(sha256.New, []byte("k"))
	mac.Write([]byte(r.Header.Get("X-Skywatch-Timestamp") + "." + string(bodies["/hook"])))
	if r.Header.Get("X-Skywatch-Signature") != "v1="+hex.EncodeToString(mac.Sum(nil)) {
		t.Error("webhook signature mismatch")
	}

	if err := n.Send(ctx, "slack", nil, map[string]string{"webhook_url": srv.URL + "/slack"}, samplePayload("opened")); err != nil {
		t.Fatal(err)
	}
	var slack map[string]any
	_ = json.Unmarshal(bodies["/slack"], &slack)
	if !strings.Contains(slack["text"].(string), "[CRITICAL] INC-42") {
		t.Errorf("slack text = %v", slack["text"])
	}
	if !strings.Contains(string(bodies["/slack"]), "https://skywatch.example/incidents/inc-1") {
		t.Error("slack message missing incident link")
	}

	if err := n.Send(ctx, "teams", nil, map[string]string{"webhook_url": srv.URL + "/teams"}, samplePayload("resolved")); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(bodies["/teams"]), "application/vnd.microsoft.card.adaptive") || !strings.Contains(string(bodies["/teams"]), "[RESOLVED]") {
		t.Errorf("teams body = %s", bodies["/teams"])
	}
}

func TestPermanentErrors(t *testing.T) {
	n := &Notifier{}
	if err := n.Send(context.Background(), "webhook", nil, map[string]string{"url": "http://insecure.example"}, samplePayload("opened")); !errors.Is(err, errPermanent) {
		t.Errorf("http (non-TLS) webhook must be rejected permanently: %v", err)
	}
	if err := n.Send(context.Background(), "email", map[string]any{"to": []any{"a@b.c"}}, nil, samplePayload("opened")); !errors.Is(err, errPermanent) {
		t.Errorf("email without SMTP must be permanent: %v", err)
	}
}

func TestEmailHeaderInjectionPrevented(t *testing.T) {
	var sent []byte
	var rcpt []string
	n := &Notifier{cfg: Config{SMTPAddr: "smtp.example:587", SMTPFrom: "noc@example.com"},
		SendMail: func(addr string, a smtp.Auth, from string, to []string, msg []byte) error { sent, rcpt = msg, to; return nil }}
	p := samplePayload("opened")
	p["incident"].(map[string]any)["title"] = "evil\r\nBcc: attacker@example.com"
	if err := n.Send(context.Background(), "email", map[string]any{"to": []any{"oncall@example.com", "x@y.z\r\nBcc: z@z"}}, nil, p); err != nil {
		t.Fatal(err)
	}
	if len(rcpt) != 1 || strings.Contains(string(sent), "\r\nBcc:") {
		t.Fatalf("header injection not prevented: %v %q", rcpt, sent)
	}
}
