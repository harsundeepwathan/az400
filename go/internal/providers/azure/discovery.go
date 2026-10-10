package azure

import (
	"context"
	"fmt"
	"strings"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore/to"
	"github.com/Azure/azure-sdk-for-go/sdk/resourcemanager/resourcegraph/armresourcegraph"

	"github.com/harsundeepwathan/az400/go/internal/model"
	"github.com/harsundeepwathan/az400/go/internal/providers"
)

// nativeTypes maps the Azure resource types Skywatch monitors to normalized types.
// Microsoft.Web/sites is split into app_service / function_app by "kind".
var nativeTypes = map[string]model.ResourceType{
	"microsoft.compute/virtualmachines":          model.TypeVM,
	"microsoft.compute/virtualmachinescalesets":  model.TypeVMScaleSet,
	"microsoft.web/sites":                        model.TypeAppService,
	"microsoft.sql/servers/databases":            model.TypeSQLDatabase,
	"microsoft.storage/storageaccounts":          model.TypeStorageAccount,
	"microsoft.network/loadbalancers":            model.TypeLoadBalancer,
	"microsoft.network/applicationgateways":      model.TypeAppGateway,
	"microsoft.network/azurefirewalls":           model.TypeFirewall,
	"microsoft.network/virtualnetworkgateways":   model.TypeVPNGateway,
	"microsoft.containerservice/managedclusters": model.TypeK8sCluster,
}

const inventoryQuery = `resources
| where type in~ (%s)
| where not(type =~ 'microsoft.sql/servers/databases' and name =~ 'master')
| extend powerState = tostring(properties.extended.instanceView.powerState.code),
         osType = tostring(properties.storageProfile.osDisk.osType),
         osName = tostring(properties.extended.instanceView.osName),
         vmSize = tostring(properties.hardwareProfile.vmSize),
         siteState = tostring(properties.state),
         dbStatus = tostring(properties.status),
         aksPower = tostring(properties.powerState.code),
         opState = tostring(properties.operationalState),
         provisioningState = tostring(properties.provisioningState),
         vmId = tostring(properties.vmId)
| project id, name, type, kind, location, resourceGroup, subscriptionId, tags, sku,
          powerState, osType, osName, vmSize, siteState, dbStatus, aksPower, opState, provisioningState, vmId`

// lbMembershipQuery maps VMs to the load balancers whose backend pools reference their NICs.
const lbMembershipQuery = `resources
| where type =~ 'microsoft.network/networkinterfaces'
| where isnotempty(properties.virtualMachine.id)
| mv-expand ipc = properties.ipConfigurations
| mv-expand pool = ipc.properties.loadBalancerBackendAddressPools
| where isnotempty(pool.id)
| project vmId = tolower(tostring(properties.virtualMachine.id)), poolId = tolower(tostring(pool.id))`

const subscriptionsQuery = `resourcecontainers
| where type =~ 'microsoft.resources/subscriptions'
| project subscriptionId, name, state = tostring(properties.state)`

func typeList() string {
	parts := make([]string, 0, len(nativeTypes))
	for t := range nativeTypes {
		parts = append(parts, "'"+t+"'")
	}
	return strings.Join(parts, ",")
}

// queryGraph runs a Resource Graph query across the configured subscriptions,
// following $skipToken pagination.
func (a *Adapter) queryGraph(ctx context.Context, acct providers.Account, cfg accountConfig, query string) ([]map[string]any, error) {
	cred, err := a.credential(acct, cfg)
	if err != nil {
		return nil, err
	}
	client, err := armresourcegraph.NewClient(cred, a.armOptions(cfg))
	if err != nil {
		return nil, err
	}
	req := armresourcegraph.QueryRequest{
		Query: to.Ptr(query),
		Options: &armresourcegraph.QueryRequestOptions{
			ResultFormat: to.Ptr(armresourcegraph.ResultFormatObjectArray),
			Top:          to.Ptr[int32](1000),
		},
	}
	if len(cfg.SubscriptionIDs) > 0 {
		req.Subscriptions = to.SliceOfPtrs(cfg.SubscriptionIDs...)
	}
	var rows []map[string]any
	for page := 0; page < 200; page++ { // hard stop: 200k rows
		resp, err := client.Resources(ctx, req, nil)
		if err != nil {
			return nil, classify(err)
		}
		data, _ := resp.Data.([]any)
		for _, d := range data {
			if m, ok := d.(map[string]any); ok {
				rows = append(rows, m)
			}
		}
		if resp.SkipToken == nil || *resp.SkipToken == "" {
			return rows, nil
		}
		req.Options.SkipToken = resp.SkipToken
	}
	return rows, fmt.Errorf("resource graph pagination exceeded limit")
}

// Discover implements providers.Adapter.
func (a *Adapter) Discover(ctx context.Context, acct providers.Account) ([]model.DiscoveredResource, error) {
	cfg := parseConfig(acct)
	rows, err := a.queryGraph(ctx, acct, cfg, fmt.Sprintf(inventoryQuery, typeList()))
	if err != nil {
		return nil, fmt.Errorf("discover resources: %w", err)
	}
	out := make([]model.DiscoveredResource, 0, len(rows))
	byID := map[string]int{}
	for _, r := range rows {
		d, ok := mapRow(r)
		if !ok {
			continue
		}
		byID[d.ProviderResourceID] = len(out)
		out = append(out, d)
	}

	// Relationship enrichment is best effort: a failure here must not fail discovery.
	if memberships, err := a.queryGraph(ctx, acct, cfg, lbMembershipQuery); err == nil {
		for _, m := range memberships {
			vmID, _ := m["vmId"].(string)
			poolID, _ := m["poolId"].(string)
			i := strings.Index(poolID, "/backendaddresspools/")
			if vmID == "" || i < 0 {
				continue
			}
			lbID := poolID[:i]
			if idx, ok := byID[vmID]; ok {
				if _, lbKnown := byID[lbID]; lbKnown && !hasRelation(out[idx].Relations, lbID) {
					out[idx].Relations = append(out[idx].Relations, model.Relation{ToProviderResourceID: lbID, Kind: "backend_of"})
				}
			}
		}
	}
	return out, nil
}

func hasRelation(rs []model.Relation, to string) bool {
	for _, r := range rs {
		if r.ToProviderResourceID == to {
			return true
		}
	}
	return false
}

func str(m map[string]any, k string) string {
	if v, ok := m[k].(string); ok {
		return v
	}
	return ""
}

// mapRow converts one Resource Graph row into a normalized resource.
func mapRow(r map[string]any) (model.DiscoveredResource, bool) {
	native := strings.ToLower(str(r, "type"))
	rt, ok := nativeTypes[native]
	if !ok {
		return model.DiscoveredResource{}, false
	}
	kind := strings.ToLower(str(r, "kind"))
	if native == "microsoft.web/sites" && strings.Contains(kind, "functionapp") {
		rt = model.TypeFunctionApp
	}
	d := model.DiscoveredResource{
		// Azure resource IDs are case-insensitive; normalize so agents reporting their
		// IMDS resourceId match discovery regardless of casing.
		ProviderResourceID: strings.ToLower(str(r, "id")),
		ExternalAccountID:  str(r, "subscriptionId"),
		Name:               str(r, "name"),
		Type:               rt,
		NativeType:         native,
		Region:             str(r, "location"),
		ResourceGroup:      str(r, "resourceGroup"),
		Tags:               map[string]string{},
		Config:             map[string]any{},
	}
	if tags, ok := r["tags"].(map[string]any); ok {
		for k, v := range tags {
			if s, ok := v.(string); ok {
				d.Tags[k] = s
			}
		}
	}
	if kind != "" {
		d.Config["kind"] = kind
	}
	if sku, ok := r["sku"].(map[string]any); ok && len(sku) > 0 {
		d.Config["sku"] = sku
	}
	if v := str(r, "vmSize"); v != "" {
		d.Config["vm_size"] = v
	}
	if v := str(r, "vmId"); v != "" {
		d.Config["vm_id"] = v
	}
	if v := str(r, "provisioningState"); v != "" {
		d.Config["provisioning_state"] = v
	}

	switch rt {
	case model.TypeVM:
		code := str(r, "powerState")
		d.ProviderStateRaw = code
		d.PowerState = vmPowerState(code)
		switch strings.ToLower(str(r, "osType")) {
		case "windows":
			d.OSType = "windows"
		case "linux":
			d.OSType = "linux"
		}
		d.OSName = str(r, "osName")
	case model.TypeAppService, model.TypeFunctionApp:
		d.ProviderStateRaw = str(r, "siteState")
		d.PowerState = runningStopped(d.ProviderStateRaw)
	case model.TypeK8sCluster:
		d.ProviderStateRaw = str(r, "aksPower")
		d.PowerState = runningStopped(d.ProviderStateRaw)
	case model.TypeAppGateway:
		d.ProviderStateRaw = str(r, "opState")
		d.PowerState = runningStopped(d.ProviderStateRaw)
	case model.TypeSQLDatabase:
		d.ProviderStateRaw = str(r, "dbStatus")
		switch strings.ToLower(d.ProviderStateRaw) {
		case "online":
			d.PowerState = model.PowerRunning
		case "paused", "offline", "shutdown":
			d.PowerState = model.PowerStopped
		case "pausing":
			d.PowerState = model.PowerStopping
		case "resuming", "creating":
			d.PowerState = model.PowerStarting
		default:
			d.PowerState = model.PowerUnknown
		}
	default:
		// Resources without a power concept: report provisioning state only.
		d.ProviderStateRaw = str(r, "provisioningState")
		d.PowerState = model.PowerNotApplicable
	}
	if ps := strings.ToLower(str(r, "provisioningState")); ps == "deleting" {
		d.PowerState = model.PowerDeleting
	} else if ps == "creating" && d.PowerState == model.PowerUnknown {
		d.PowerState = model.PowerProvisioning
	}
	return d, true
}

// vmPowerState maps PowerState/* instance view codes.
func vmPowerState(code string) model.PowerState {
	switch strings.ToLower(strings.TrimPrefix(code, "PowerState/")) {
	case "running":
		return model.PowerRunning
	case "stopped":
		return model.PowerStopped
	case "deallocated":
		return model.PowerDeallocated
	case "starting":
		return model.PowerStarting
	case "stopping", "deallocating":
		return model.PowerStopping
	default:
		return model.PowerUnknown
	}
}

func runningStopped(s string) model.PowerState {
	switch strings.ToLower(s) {
	case "running":
		return model.PowerRunning
	case "stopped":
		return model.PowerStopped
	case "starting":
		return model.PowerStarting
	case "stopping":
		return model.PowerStopping
	default:
		return model.PowerUnknown
	}
}

// ValidateCredentials implements providers.Adapter. It obtains a token, lists reachable
// subscriptions via Resource Graph and probes each read permission Skywatch relies on.
func (a *Adapter) ValidateCredentials(ctx context.Context, acct providers.Account) (*providers.ValidationReport, error) {
	cfg := parseConfig(acct)
	rep := &providers.ValidationReport{ValidatedAt: nowUTC()}
	add := func(c providers.PermissionCheck) { rep.Checks = append(rep.Checks, c) }

	subs, err := a.queryGraph(ctx, acct, cfg, subscriptionsQuery)
	if err != nil {
		add(providers.PermissionCheck{Check: "Authenticate and query Azure Resource Graph", OK: false,
			Detail: err.Error(), Missing: "Reader role on each subscription (Microsoft.ResourceGraph/resources/read)"})
		return rep, nil
	}
	visible := map[string]bool{}
	for _, s := range subs {
		id := strings.ToLower(str(s, "subscriptionId"))
		visible[id] = true
		rep.Scopes = append(rep.Scopes, fmt.Sprintf("%s (%s)", str(s, "name"), str(s, "subscriptionId")))
	}
	add(providers.PermissionCheck{Check: "Authenticate and query Azure Resource Graph", OK: true,
		Detail: fmt.Sprintf("%d subscription(s) visible", len(subs))})
	for _, want := range cfg.SubscriptionIDs {
		ok := visible[strings.ToLower(want)]
		c := providers.PermissionCheck{Check: "Subscription " + want + " readable", OK: ok}
		if !ok {
			c.Missing = "Assign the Reader and Monitoring Reader roles on subscription " + want
		}
		add(c)
	}
	if len(subs) == 0 {
		add(providers.PermissionCheck{Check: "At least one subscription visible", OK: false,
			Missing: "Assign Reader + Monitoring Reader at subscription or management group scope"})
	}

	// Probe Azure Monitor metrics and Resource Health on the first subscription.
	probeSub := ""
	if len(cfg.SubscriptionIDs) > 0 {
		probeSub = cfg.SubscriptionIDs[0]
	} else if len(subs) > 0 {
		probeSub = str(subs[0], "subscriptionId")
	}
	if probeSub != "" {
		if _, err := a.listAvailability(ctx, acct, cfg, probeSub, 1); err != nil {
			add(providers.PermissionCheck{Check: "Read Azure Resource Health", OK: false, Detail: err.Error(),
				Missing: "Microsoft.ResourceHealth/availabilityStatuses/read (included in Reader)"})
		} else {
			add(providers.PermissionCheck{Check: "Read Azure Resource Health", OK: true})
		}
		if err := a.probeActivityLog(ctx, acct, cfg, probeSub); err != nil {
			add(providers.PermissionCheck{Check: "Read Azure Activity Log", OK: false, Detail: err.Error(),
				Missing: "Microsoft.Insights/eventtypes/values/read (included in Reader / Monitoring Reader)"})
		} else {
			add(providers.PermissionCheck{Check: "Read Azure Activity Log", OK: true})
		}
	}
	for _, ws := range cfg.WorkspaceIDs {
		if err := a.probeWorkspace(ctx, acct, cfg, ws); err != nil {
			add(providers.PermissionCheck{Check: "Query Log Analytics workspace " + ws, OK: false, Detail: err.Error(),
				Missing: "Log Analytics Reader on the workspace (Microsoft.OperationalInsights/workspaces/query/read)"})
		} else {
			add(providers.PermissionCheck{Check: "Query Log Analytics workspace " + ws, OK: true})
		}
	}
	if len(cfg.WorkspaceIDs) == 0 {
		add(providers.PermissionCheck{Check: "Guest heartbeat source configured", OK: false,
			Detail:  "No Log Analytics workspace configured: guest heartbeats will come only from the Skywatch agent.",
			Missing: "Optional: add the workspace ID that receives Azure Monitor Agent Heartbeat data"})
	}

	rep.OK = true
	for _, c := range rep.Checks {
		if !c.OK && c.Check != "Guest heartbeat source configured" {
			rep.OK = false
		}
	}
	rep.Identity = acct.Credentials["client_id"]
	return rep, nil
}
