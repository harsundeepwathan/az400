package agent

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/harsundeepwathan/az400/go/pkg/telemetry"
)

// Metadata endpoints. These are link-local services only reachable from the instance.
var (
	azureIMDS   = "http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01"
	doMetadata  = "http://169.254.169.254/metadata/v1"
	aliMetadata = "http://100.100.100.200/latest/meta-data"
)

// DetectCloud reads the local instance metadata service to identify the cloud resource
// this host is, so the server can link the agent to the discovered VM. Each probe has a
// short timeout; on-premises hosts simply return an empty CloudInfo.
func DetectCloud(ctx context.Context) telemetry.CloudInfo {
	c := &http.Client{Timeout: 800 * time.Millisecond, Transport: &http.Transport{Proxy: nil}}
	get := func(url string, hdr map[string]string) (string, bool) {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		if err != nil {
			return "", false
		}
		for k, v := range hdr {
			req.Header.Set(k, v)
		}
		resp, err := c.Do(req)
		if err != nil {
			return "", false
		}
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			return "", false
		}
		b, err := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
		return strings.TrimSpace(string(b)), err == nil
	}
	if body, ok := get(azureIMDS, map[string]string{"Metadata": "true"}); ok {
		var m struct {
			ResourceID string `json:"resourceId"`
			Location   string `json:"location"`
			VMID       string `json:"vmId"`
		}
		if json.Unmarshal([]byte(body), &m) == nil && m.ResourceID != "" {
			return telemetry.CloudInfo{Provider: "azure", ResourceID: m.ResourceID, Region: m.Location, InstanceID: m.VMID}
		}
	}
	if id, ok := get(doMetadata+"/id", nil); ok && id != "" && isDigits(id) {
		region, _ := get(doMetadata+"/region", nil)
		return telemetry.CloudInfo{Provider: "digitalocean", InstanceID: id, Region: region}
	}
	if id, ok := get(aliMetadata+"/instance-id", nil); ok && strings.HasPrefix(id, "i-") {
		region, _ := get(aliMetadata+"/region-id", nil)
		return telemetry.CloudInfo{Provider: "alibaba", InstanceID: id, Region: region}
	}
	return telemetry.CloudInfo{}
}

func isDigits(s string) bool {
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return s != ""
}
