// Package model holds the provider-neutral domain types shared by collectors, the
// evaluator and the agent ingestion path.
package model

import "time"

// Provider identifies a cloud or infrastructure source.
type Provider string

const (
	ProviderAzure        Provider = "azure"
	ProviderAlibaba      Provider = "alibaba"
	ProviderDigitalOcean Provider = "digitalocean"
	ProviderOnPrem       Provider = "onprem"
	ProviderDemo         Provider = "demo"
)

// ResourceType is the normalized resource taxonomy. Provider-native types are kept in
// Resource.NativeType.
type ResourceType string

const (
	TypeVM             ResourceType = "vm"
	TypeVMScaleSet     ResourceType = "vm_scale_set"
	TypeAppService     ResourceType = "app_service"
	TypeFunctionApp    ResourceType = "function_app"
	TypeSQLDatabase    ResourceType = "sql_database"
	TypeManagedDB      ResourceType = "managed_database"
	TypeStorageAccount ResourceType = "storage_account"
	TypeObjectBucket   ResourceType = "object_bucket"
	TypeLoadBalancer   ResourceType = "load_balancer"
	TypeAppGateway     ResourceType = "app_gateway"
	TypeFirewall       ResourceType = "firewall"
	TypeVPNGateway     ResourceType = "vpn_gateway"
	TypeK8sCluster     ResourceType = "kubernetes_cluster"
	TypeVolume         ResourceType = "volume"
	TypeServer         ResourceType = "server" // agent-only host with no cloud inventory record
)

// PowerState is the provider-reported power/provisioning state. It says nothing about
// whether the guest OS or workload is healthy.
type PowerState string

const (
	PowerRunning       PowerState = "running"
	PowerStopped       PowerState = "stopped"
	PowerDeallocated   PowerState = "deallocated"
	PowerStarting      PowerState = "starting"
	PowerStopping      PowerState = "stopping"
	PowerProvisioning  PowerState = "provisioning"
	PowerDeleting      PowerState = "deleting"
	PowerUnknown       PowerState = "unknown"
	PowerNotApplicable PowerState = "not_applicable"
)

// IsOff reports whether the provider explicitly says the resource is powered off.
func (p PowerState) IsOff() bool { return p == PowerStopped || p == PowerDeallocated }

// ProviderHealth is the provider's own health signal (e.g. Azure Resource Health).
type ProviderHealth string

const (
	HealthAvailable   ProviderHealth = "available"
	HealthDegraded    ProviderHealth = "degraded"
	HealthUnavailable ProviderHealth = "unavailable"
	HealthUnknown     ProviderHealth = "unknown"
)

// OperationalState is Skywatch's computed state for a resource.
type OperationalState string

const (
	StateHealthy     OperationalState = "healthy"
	StateWarning     OperationalState = "warning"
	StateCritical    OperationalState = "critical"
	StateDown        OperationalState = "down"
	StateStopped     OperationalState = "stopped"
	StateUnknown     OperationalState = "unknown"
	StateMaintenance OperationalState = "maintenance"
	StateNoData      OperationalState = "no_data"
)

// Severity of an alert or incident.
type Severity string

const (
	SeverityWarning  Severity = "warning"
	SeverityCritical Severity = "critical"
)

// DiscoveredResource is what a provider adapter returns from discovery.
type DiscoveredResource struct {
	ProviderResourceID string
	ExternalAccountID  string
	Name               string
	Type               ResourceType
	NativeType         string
	Region             string
	ResourceGroup      string
	Tags               map[string]string
	OSType             string // windows | linux | "" when unknown
	OSName             string
	Config             map[string]any
	ProviderStateRaw   string
	PowerState         PowerState
	// Relations to other discovered resources, by provider resource id.
	Relations []Relation
}

// Relation links two resources for correlation purposes.
type Relation struct {
	ToProviderResourceID string
	Kind                 string // depends_on | member_of | backend_of | attached_to
}

// Environment derives the environment label from conventional tags.
func (d DiscoveredResource) Environment() string {
	for _, k := range []string{"environment", "Environment", "env", "Env", "ENV"} {
		if v, ok := d.Tags[k]; ok && v != "" {
			return v
		}
	}
	return ""
}

// Sample is one normalized measurement.
type Sample struct {
	Metric string
	Series string // e.g. "mount=/var" or "core=3"; empty for scalar metrics
	TS     time.Time
	Value  float64
}

// ResourceRef identifies a resource for metric/health collection.
type ResourceRef struct {
	ID                 string // Skywatch resource UUID
	ProviderResourceID string
	Type               ResourceType
	Region             string
	OSType             string
	PowerState         PowerState
	Config             map[string]any
}

// HealthObservation is a provider health signal for a resource.
type HealthObservation struct {
	ProviderResourceID string
	Health             ProviderHealth
	Reason             string
	ObservedAt         time.Time
}

// HeartbeatObservation is a guest heartbeat retrieved from a provider-side source
// (e.g. the Azure Monitor Agent Heartbeat table), distinct from Skywatch agent heartbeats.
type HeartbeatObservation struct {
	ProviderResourceID string
	Computer           string
	LastHeartbeat      time.Time
	Source             string
}

// Event is an infrastructure change/event (e.g. Azure Activity Log entry).
type Event struct {
	ProviderResourceID string
	ExternalID         string
	Kind               string
	Severity           string
	Message            string
	At                 time.Time
	Details            map[string]any
}
