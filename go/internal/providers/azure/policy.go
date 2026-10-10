package azure

import (
	"net/http"
	"strconv"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"

	"github.com/harsundeepwathan/az400/go/internal/providers"
)

// statsPolicy counts outbound HTTP attempts and throttled (429) responses into the
// CallStats attached to the request context. It runs per retry, so every attempt the SDK
// retry loop makes is counted.
type statsPolicy struct{}

func (statsPolicy) Do(req *policy.Request) (*http.Response, error) {
	stats := providers.StatsFrom(req.Raw().Context())
	stats.AddCall()
	resp, err := req.Next()
	if resp != nil && resp.StatusCode == http.StatusTooManyRequests {
		stats.AddThrottled()
	}
	return resp, err
}

// retryAfter parses Retry-After (seconds) or Azure's x-ms-ratelimit-* hints.
func retryAfter(resp *http.Response) time.Duration {
	if resp == nil {
		return time.Minute
	}
	for _, h := range []string{"Retry-After", "retry-after-ms", "x-ms-retry-after-ms"} {
		v := resp.Header.Get(h)
		if v == "" {
			continue
		}
		if n, err := strconv.Atoi(v); err == nil {
			if h == "Retry-After" {
				return time.Duration(n) * time.Second
			}
			return time.Duration(n) * time.Millisecond
		}
	}
	return time.Minute
}
