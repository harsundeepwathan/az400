package azure

import (
	"github.com/harsundeepwathan/az400/go/internal/model"
	"github.com/harsundeepwathan/az400/go/internal/providers"
)

// Capabilities implements providers.Adapter.
func (a *Adapter) Capabilities() []providers.Capability {
	return []providers.Capability{
		{Key: "auth.client_secret", Title: "Entra ID application (client secret)", Status: providers.Implemented},
		{Key: "auth.client_certificate", Title: "Entra ID application (certificate)", Status: providers.Implemented},
		{Key: "auth.managed_identity", Title: "Managed identity (Skywatch hosted in Azure)", Status: providers.Experimental,
			Notes: "Only usable when the collector itself runs on Azure compute with an identity assigned."},
		{Key: "auth.workload_identity_federation", Title: "Workload identity federation", Status: providers.NotImplemented},
		{Key: "discovery", Title: "Resource discovery (Azure Resource Graph)", Status: providers.Implemented,
			Requires:     []string{"Reader on subscriptions or management group"},
			ResourceType: []string{"vm", "vm_scale_set", "app_service", "function_app", "sql_database", "storage_account", "load_balancer", "app_gateway", "firewall", "vpn_gateway", "kubernetes_cluster"}},
		{Key: "multi_subscription", Title: "Multiple subscriptions per account", Status: providers.Implemented},
		{Key: "multi_tenant", Title: "Multiple tenants", Status: providers.Implemented, Notes: "Add one cloud account per tenant."},
		{Key: "power_state", Title: "VM power state", Status: providers.Implemented,
			Notes: "From Resource Graph properties.extended.instanceView.powerState; refreshed on each discovery run."},
		{Key: "platform_metrics", Title: "Azure Monitor platform metrics", Status: providers.Implemented,
			Requires: []string{"Monitoring Reader (or Reader)"}},
		{Key: "provider_health", Title: "Azure Resource Health", Status: providers.Implemented},
		{Key: "activity_log", Title: "Activity Log change events and Service Health", Status: providers.Implemented},
		{Key: "guest_heartbeat", Title: "Guest heartbeat (Azure Monitor Agent → Log Analytics)", Status: providers.Implemented,
			Requires: []string{"Azure Monitor Agent + DCR sending Heartbeat to a workspace", "Log Analytics Reader on the workspace"}},
		{Key: "guest_metrics", Title: "Guest disk/memory (VM Insights → InsightsMetrics)", Status: providers.Experimental,
			Requires: []string{"VM Insights enabled with Azure Monitor Agent", "Log Analytics Reader on the workspace"}},
		{Key: "guest_services", Title: "Windows/Linux service state", Status: providers.Unsupported,
			Notes: "Use the Skywatch agent. Azure Change Tracking data is not ingested."},
		{Key: "multi_resource_metrics", Title: "Batch metrics API (metrics.monitor.azure.com)", Status: providers.NotImplemented,
			Notes: "Planned optimisation for large estates; per-resource ARM metrics calls are used today."},
	}
}

// MetricSupport implements providers.Adapter.
func (a *Adapter) MetricSupport() []providers.MetricSupport {
	var out []providers.MetricSupport
	for rt, maps := range platformMetrics {
		for _, m := range maps {
			out = append(out, providers.MetricSupport{ResourceType: rt, Metric: m.Normalized, NativeMetric: m.Native})
		}
	}
	for _, m := range []string{"disk.utilization", "disk.total_bytes", "memory.utilization", "memory.total_bytes"} {
		out = append(out, providers.MetricSupport{ResourceType: model.TypeVM, Metric: m, NativeMetric: "InsightsMetrics (VM Insights)",
			RequiresAgent: true, Notes: "Requires Azure Monitor Agent with VM Insights and a configured workspace"})
	}
	return out
}
