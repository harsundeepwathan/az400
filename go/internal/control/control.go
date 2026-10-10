// Package control is the internal API the management API (apps/api) uses to run
// provider operations that only the Go adapters can perform: credential validation,
// on-demand discovery and test notifications. It listens on a private address and
// requires a shared bearer token; it must never be exposed publicly.
package control

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/harsundeepwathan/az400/go/internal/collector"
	"github.com/harsundeepwathan/az400/go/internal/model"
	"github.com/harsundeepwathan/az400/go/internal/notify"
	"github.com/harsundeepwathan/az400/go/internal/providers"
)

// Server is the control API.
type Server struct {
	Pool      *pgxpool.Pool
	Scheduler *collector.Scheduler
	Notifier  *notify.Notifier
	Token     string
	Log       *slog.Logger
}

// Handler returns the HTTP handler.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /internal/accounts/{org}/{id}/validate", s.validate)
	mux.HandleFunc("POST /internal/accounts/{org}/{id}/discover", s.discover)
	mux.HandleFunc("POST /internal/channels/{org}/{id}/test", s.testChannel)
	mux.HandleFunc("GET /internal/providers", s.capabilities)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got := []byte(r.Header.Get("Authorization"))
		want := []byte("Bearer " + s.Token)
		if s.Token == "" || subtle.ConstantTimeCompare(got, want) != 1 {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		mux.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func (s *Server) adapter(w http.ResponseWriter, r *http.Request) (providers.Adapter, providers.Account, bool) {
	acct, provider, err := s.Scheduler.LoadAccount(r.Context(), r.PathValue("org"), r.PathValue("id"))
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
		return nil, acct, false
	}
	ad, ok := s.Scheduler.Adapter(provider)
	if acct.AuthMethod == "demo" {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "demo": true})
		return nil, acct, false
	}
	if !ok {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "provider " + string(provider) + " is not implemented"})
		return nil, acct, false
	}
	return ad, acct, true
}

func (s *Server) validate(w http.ResponseWriter, r *http.Request) {
	ad, acct, ok := s.adapter(w, r)
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 90*time.Second)
	defer cancel()
	rep, err := ad.ValidateCredentials(ctx, acct)
	if err != nil {
		rep = &providers.ValidationReport{Checks: []providers.PermissionCheck{{Check: "Validate credentials", Detail: err.Error()}}}
	}
	caps, _ := json.Marshal(map[string]any{"capabilities": ad.Capabilities(), "metrics": ad.MetricSupport()})
	report, _ := json.Marshal(rep)
	status := "error"
	reason := "Validation failed: see permission report"
	if rep.OK {
		status, reason = "validating", ""
	}
	_, err = s.Pool.Exec(r.Context(), `UPDATE cloud_accounts SET permission_report=$3, capabilities=$4, last_validated_at=now(),
		status = CASE WHEN status IN ('active','degraded','disabled') AND $5 THEN status ELSE $6 END,
		status_reason = CASE WHEN $5 THEN status_reason ELSE $7 END, updated_at=now()
		WHERE id=$1 AND org_id=$2`, acct.ID, acct.OrgID, report, caps, rep.OK, status, nullable(reason))
	if err != nil {
		s.Log.Error("store validation", "err", err)
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": rep.OK, "report": rep, "capabilities": ad.Capabilities(), "metrics": ad.MetricSupport()})
}

func nullable(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func (s *Server) discover(w http.ResponseWriter, r *http.Request) {
	ad, acct, ok := s.adapter(w, r)
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Minute)
	defer cancel()
	found, err := ad.Discover(ctx, acct)
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	type item struct {
		ProviderID string `json:"provider_resource_id"`
		Name       string `json:"name"`
		Type       string `json:"type"`
		Region     string `json:"region"`
		Power      string `json:"power_state"`
		OS         string `json:"os_type"`
	}
	out := make([]item, 0, len(found))
	for _, d := range found {
		out = append(out, item{d.ProviderResourceID, d.Name, string(d.Type), d.Region, string(d.PowerState), d.OSType})
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "resources": out})
}

func (s *Server) testChannel(w http.ResponseWriter, r *http.Request) {
	if s.Notifier == nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": "notifier role not running in this process"})
		return
	}
	err := s.Notifier.SendTest(r.Context(), r.PathValue("org"), r.PathValue("id"))
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) capabilities(w http.ResponseWriter, r *http.Request) {
	out := map[string]any{}
	for _, p := range []string{"azure", "digitalocean", "alibaba"} {
		if ad, ok := s.Scheduler.Adapter(providerName(p)); ok {
			out[p] = map[string]any{"capabilities": ad.Capabilities(), "metrics": ad.MetricSupport()}
		}
	}
	writeJSON(w, http.StatusOK, out)
}

func providerName(p string) model.Provider { return model.Provider(p) }
