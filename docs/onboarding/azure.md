# Onboarding Microsoft Azure (least privilege)

Skywatch reads Azure through **Resource Graph**, **Azure Monitor Metrics**, **Resource
Health**, the **Activity Log**, and optionally **Log Analytics**. It never writes.

## 1. Create the identity

Use one Entra ID application per tenant. A certificate credential is preferred over a
client secret.

```bash
az ad app create --display-name skywatch-reader
APP_ID=$(az ad app list --display-name skywatch-reader --query '[0].appId' -o tsv)
az ad sp create --id "$APP_ID"
# Certificate (recommended): upload the public part, keep the PEM (cert + private key) for Skywatch
az ad app credential reset --id "$APP_ID" --cert @skywatch.crt --append
# …or a client secret with a short lifetime
az ad app credential reset --id "$APP_ID" --years 1
```

When Skywatch itself runs on Azure compute, choose **Managed identity** instead and
assign the roles to that identity. No secret is stored.

## 2. Assign roles

At subscription (or management-group) scope:

```bash
for SUB in <subscription-id> …; do
  az role assignment create --assignee "$APP_ID" --role "Reader"            --scope "/subscriptions/$SUB"
  az role assignment create --assignee "$APP_ID" --role "Monitoring Reader" --scope "/subscriptions/$SUB"
done
```

Optional guest heartbeat and VM Insights (Azure Monitor Agent → Log Analytics):

```bash
az role assignment create --assignee "$APP_ID" --role "Log Analytics Reader" \
  --scope /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<ws>
```

### Narrower custom role (alternative to Reader)

Resource Graph returns only resources the identity can read, so a custom role must
list read actions for every monitored type:

```json
{
  "Name": "Skywatch Monitoring Reader",
  "IsCustom": true,
  "Actions": [
    "Microsoft.Resources/subscriptions/read",
    "Microsoft.Resources/subscriptions/resourceGroups/read",
    "Microsoft.ResourceGraph/resources/read",
    "Microsoft.Compute/virtualMachines/read",
    "Microsoft.Compute/virtualMachineScaleSets/read",
    "Microsoft.Web/sites/read",
    "Microsoft.Sql/servers/databases/read",
    "Microsoft.Storage/storageAccounts/read",
    "Microsoft.Network/loadBalancers/read",
    "Microsoft.Network/networkInterfaces/read",
    "Microsoft.Network/applicationGateways/read",
    "Microsoft.Network/azureFirewalls/read",
    "Microsoft.Network/virtualNetworkGateways/read",
    "Microsoft.ContainerService/managedClusters/read",
    "Microsoft.Insights/metrics/read",
    "Microsoft.Insights/metricDefinitions/read",
    "Microsoft.Insights/eventtypes/values/read",
    "Microsoft.ResourceHealth/availabilityStatuses/read"
  ],
  "AssignableScopes": ["/subscriptions/<sub>"]
}
```

## 3. Connect in Skywatch

Go to **Cloud accounts → Connect account → Microsoft Azure** and enter:
- tenant ID
- client ID
- the secret or the certificate PEM
- subscription IDs (empty = every readable subscription)
- workspace IDs (optional)

The wizard validates by:
1. querying `resourcecontainers` through Resource Graph (lists the visible subscriptions)
2. listing Resource Health statuses
3. reading one hour of Activity Log
4. querying each workspace

Any failed check names the missing role or action.

## What is collected

| Data | API | Interval |
|---|---|---|
| Inventory and VM power state | Resource Graph (`2024-04-01`), `properties.extended.instanceView.powerState` | 5 min |
| Platform metrics | `Microsoft.Insights/metrics` (`2024-02-01`), PT1M, 15-min overlapping window | 2 min |
| Resource Health | `Microsoft.ResourceHealth/availabilityStatuses` (`2025-05-01`) | 5 min |
| Activity Log incl. Service Health | `eventtypes/management/values` | 5 min |
| Guest heartbeat | Log Analytics `Heartbeat` table | 2 min |
| Guest disk/memory (experimental) | Log Analytics `InsightsMetrics` (VM Insights) | 2 min |

**Guest OS metrics.** Azure platform metrics cannot show per-volume disk usage or memory
utilization. Install the Skywatch agent, or enable VM Insights with the Azure Monitor
Agent and configure the workspace. Without either, Skywatch shows those metrics as
unavailable, with the reason.
