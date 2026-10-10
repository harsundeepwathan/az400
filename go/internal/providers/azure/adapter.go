// Package azure implements the Microsoft Azure provider adapter using the official
// Azure SDK for Go:
//
//   - Azure Resource Graph        discovery, VM power state (properties.extended.instanceView)
//   - Azure Monitor Metrics       platform metrics (Microsoft.Insights/metrics, 2024-02-01)
//   - Azure Resource Health       provider-side availability (Microsoft.ResourceHealth, 2025-05-01)
//   - Azure Activity Log          change and Service Health events
//   - Azure Monitor Logs          guest heartbeat (Heartbeat table, Azure Monitor Agent) and
//     VM Insights guest metrics (InsightsMetrics), when a workspace is configured
//
// All calls are read-only. Required RBAC is documented in docs/onboarding/azure.md.
package azure

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"sync"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/arm"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/cloud"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/Azure/azure-sdk-for-go/sdk/monitor/query/azlogs"

	"github.com/harsundeepwathan/az400/go/internal/model"
	"github.com/harsundeepwathan/az400/go/internal/providers"
)

// Auth methods accepted in cloud_accounts.auth_method.
const (
	AuthClientSecret    = "client_secret"
	AuthCertificate     = "client_certificate"
	AuthManagedIdentity = "managed_identity"
)

// Options customise the adapter; zero value targets Azure public cloud.
type Options struct {
	// Transport overrides the HTTP transport (used by contract tests).
	Transport policy.Transporter
	// Cloud overrides cloud endpoints (used by contract tests and sovereign clouds).
	Cloud *cloud.Configuration
	// Credential, when set, is used instead of building one from the account
	// (used by contract tests).
	Credential azcore.TokenCredential
	// MaxRetries for the SDK retry policy (429/5xx). Default 3.
	MaxRetries int32
	// Concurrency bounds per-account metric calls. Default 8.
	Concurrency int
}

// Adapter implements providers.Adapter for Azure.
type Adapter struct {
	opts Options
}

// New returns an Azure adapter.
func New(opts Options) *Adapter {
	if opts.MaxRetries == 0 {
		opts.MaxRetries = 3
	}
	if opts.Concurrency <= 0 {
		opts.Concurrency = 8
	}
	return &Adapter{opts: opts}
}

// Provider implements providers.Adapter.
func (a *Adapter) Provider() model.Provider { return model.ProviderAzure }

// accountConfig is the non-secret part of an Azure cloud account.
type accountConfig struct {
	TenantID        string
	SubscriptionIDs []string
	WorkspaceIDs    []string
	CloudName       string
}

func parseConfig(acct providers.Account) accountConfig {
	c := accountConfig{TenantID: acct.Credentials["tenant_id"]}
	if v, ok := acct.Config["tenant_id"].(string); ok && v != "" {
		c.TenantID = v
	}
	c.SubscriptionIDs = stringSlice(acct.Config["subscription_ids"])
	c.WorkspaceIDs = stringSlice(acct.Config["log_analytics_workspace_ids"])
	if v, ok := acct.Config["cloud"].(string); ok {
		c.CloudName = v
	}
	return c
}

func stringSlice(v any) []string {
	switch t := v.(type) {
	case []string:
		return t
	case []any:
		out := make([]string, 0, len(t))
		for _, x := range t {
			if s, ok := x.(string); ok && strings.TrimSpace(s) != "" {
				out = append(out, strings.TrimSpace(s))
			}
		}
		return out
	}
	return nil
}

func (a *Adapter) cloudConfig(c accountConfig) cloud.Configuration {
	if a.opts.Cloud != nil {
		return *a.opts.Cloud
	}
	switch c.CloudName {
	case "AzureUSGovernment":
		return cloud.AzureGovernment
	case "AzureChina":
		return cloud.AzureChina
	default:
		return cloud.AzurePublic
	}
}

func (a *Adapter) clientOptions(c accountConfig) azcore.ClientOptions {
	o := azcore.ClientOptions{
		Cloud: a.cloudConfig(c),
		Retry: policy.RetryOptions{MaxRetries: a.opts.MaxRetries},
		Telemetry: policy.TelemetryOptions{
			ApplicationID: "skywatch-monitor",
		},
		PerRetryPolicies: []policy.Policy{statsPolicy{}},
	}
	if a.opts.Transport != nil {
		o.Transport = a.opts.Transport
	}
	return o
}

func (a *Adapter) armOptions(c accountConfig) *arm.ClientOptions {
	return &arm.ClientOptions{ClientOptions: a.clientOptions(c)}
}

func (a *Adapter) logsOptions(c accountConfig) *azlogs.ClientOptions {
	return &azlogs.ClientOptions{ClientOptions: a.clientOptions(c)}
}

// credential builds a token credential for the account. Credentials are cached per
// account so that token refresh is shared between collection runs.
func (a *Adapter) credential(acct providers.Account, c accountConfig) (azcore.TokenCredential, error) {
	if a.opts.Credential != nil {
		return a.opts.Credential, nil
	}
	key := acct.ID + "|" + acct.Credentials["client_id"] + "|" + acct.AuthMethod
	credCache.mu.Lock()
	defer credCache.mu.Unlock()
	if cred, ok := credCache.m[key]; ok && credCache.fp[key] == fingerprint(acct.Credentials) {
		return cred, nil
	}
	cred, err := buildCredential(acct, c, a.clientOptions(c))
	if err != nil {
		return nil, err
	}
	credCache.m[key] = cred
	credCache.fp[key] = fingerprint(acct.Credentials)
	return cred, nil
}

var credCache = struct {
	mu sync.Mutex
	m  map[string]azcore.TokenCredential
	fp map[string]string
}{m: map[string]azcore.TokenCredential{}, fp: map[string]string{}}

func fingerprint(c providers.Credentials) string {
	h := sha256.New()
	for _, k := range []string{"tenant_id", "client_id", "client_secret", "certificate_pem"} {
		h.Write([]byte(k + "=" + c[k] + "\x00"))
	}
	return hex.EncodeToString(h.Sum(nil))
}

func buildCredential(acct providers.Account, c accountConfig, co azcore.ClientOptions) (azcore.TokenCredential, error) {
	switch acct.AuthMethod {
	case AuthClientSecret:
		tid, cid, sec := c.TenantID, acct.Credentials["client_id"], acct.Credentials["client_secret"]
		if tid == "" || cid == "" || sec == "" {
			return nil, fmt.Errorf("%w: tenant_id, client_id and client_secret are required", providers.ErrInvalidCreds)
		}
		return azidentity.NewClientSecretCredential(tid, cid, sec, &azidentity.ClientSecretCredentialOptions{ClientOptions: co})
	case AuthCertificate:
		tid, cid, pem := c.TenantID, acct.Credentials["client_id"], acct.Credentials["certificate_pem"]
		if tid == "" || cid == "" || pem == "" {
			return nil, fmt.Errorf("%w: tenant_id, client_id and certificate_pem are required", providers.ErrInvalidCreds)
		}
		certs, key, err := azidentity.ParseCertificates([]byte(pem), nil)
		if err != nil {
			return nil, fmt.Errorf("%w: parse certificate: %v", providers.ErrInvalidCreds, err)
		}
		return azidentity.NewClientCertificateCredential(tid, cid, certs, key,
			&azidentity.ClientCertificateCredentialOptions{ClientOptions: co})
	case AuthManagedIdentity:
		o := &azidentity.ManagedIdentityCredentialOptions{ClientOptions: co}
		if cid := acct.Credentials["client_id"]; cid != "" {
			o.ID = azidentity.ClientID(cid)
		}
		return azidentity.NewManagedIdentityCredential(o)
	default:
		return nil, fmt.Errorf("%w: unsupported auth method %q", providers.ErrInvalidCreds, acct.AuthMethod)
	}
}

// classify maps SDK errors onto platform error classes.
func classify(err error) error {
	if err == nil {
		return nil
	}
	var authErr *azidentity.AuthenticationFailedError
	if errors.As(err, &authErr) {
		return fmt.Errorf("%w: %s", providers.ErrInvalidCreds, firstLine(authErr.Error()))
	}
	var re *azcore.ResponseError
	if errors.As(err, &re) {
		switch re.StatusCode {
		case http.StatusUnauthorized:
			return fmt.Errorf("%w: %s", providers.ErrInvalidCreds, re.ErrorCode)
		case http.StatusForbidden:
			return fmt.Errorf("%w: %s", providers.ErrForbidden, re.ErrorCode)
		case http.StatusTooManyRequests:
			return &providers.ThrottledError{RetryAfter: retryAfter(re.RawResponse), Detail: re.ErrorCode}
		}
		return fmt.Errorf("azure %s: HTTP %d %s", re.RawResponse.Request.URL.Path, re.StatusCode, re.ErrorCode)
	}
	return err
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i > 0 {
		return s[:i]
	}
	return s
}
