package azure

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/monitor/query/azlogs"
	"github.com/Azure/azure-sdk-for-go/sdk/resourcemanager/monitor/armmonitor"
	"github.com/Azure/azure-sdk-for-go/sdk/resourcemanager/resourcehealth/armresourcehealth"

	"github.com/harsundeepwathan/az400/go/internal/model"
	"github.com/harsundeepwathan/az400/go/internal/providers"
)

var nowUTC = func() time.Time { return time.Now().UTC() }

func (a *Adapter) subscriptions(ctx context.Context, acct providers.Account, cfg accountConfig) ([]string, error) {
	if len(cfg.SubscriptionIDs) > 0 {
		return cfg.SubscriptionIDs, nil
	}
	rows, err := a.queryGraph(ctx, acct, cfg, subscriptionsQuery)
	if err != nil {
		return nil, err
	}
	out := make([]string, 0, len(rows))
	for _, r := range rows {
		out = append(out, str(r, "subscriptionId"))
	}
	return out, nil
}

// listAvailability lists Resource Health availability statuses for a subscription.
// limit <= 0 means all pages.
func (a *Adapter) listAvailability(ctx context.Context, acct providers.Account, cfg accountConfig, sub string, limit int) ([]*armresourcehealth.AvailabilityStatus, error) {
	cred, err := a.credential(acct, cfg)
	if err != nil {
		return nil, err
	}
	client, err := armresourcehealth.NewAvailabilityStatusesClient(sub, cred, a.armOptions(cfg))
	if err != nil {
		return nil, err
	}
	var out []*armresourcehealth.AvailabilityStatus
	pager := client.NewListBySubscriptionIDPager(nil)
	for pager.More() {
		page, err := pager.NextPage(ctx)
		if err != nil {
			return nil, classify(err)
		}
		out = append(out, page.Value...)
		if limit > 0 && len(out) >= limit {
			break
		}
	}
	return out, nil
}

// CollectHealth implements providers.Adapter using Azure Resource Health.
func (a *Adapter) CollectHealth(ctx context.Context, acct providers.Account, refs []model.ResourceRef) ([]model.HealthObservation, error) {
	cfg := parseConfig(acct)
	subs, err := a.subscriptions(ctx, acct, cfg)
	if err != nil {
		return nil, err
	}
	want := map[string]bool{}
	for _, r := range refs {
		want[strings.ToLower(r.ProviderResourceID)] = true
	}
	var out []model.HealthObservation
	for _, sub := range subs {
		statuses, err := a.listAvailability(ctx, acct, cfg, sub, 0)
		if err != nil {
			return out, err
		}
		for _, s := range statuses {
			if obs, ok := mapAvailability(s); ok && want[obs.ProviderResourceID] {
				out = append(out, obs)
			}
		}
	}
	return out, nil
}

const availabilitySuffix = "/providers/microsoft.resourcehealth/availabilitystatuses/current"

func mapAvailability(s *armresourcehealth.AvailabilityStatus) (model.HealthObservation, bool) {
	if s == nil || s.ID == nil || s.Properties == nil {
		return model.HealthObservation{}, false
	}
	id := strings.ToLower(*s.ID)
	if !strings.HasSuffix(id, availabilitySuffix) {
		return model.HealthObservation{}, false
	}
	obs := model.HealthObservation{
		ProviderResourceID: strings.TrimSuffix(id, availabilitySuffix),
		Health:             model.HealthUnknown,
		ObservedAt:         nowUTC(),
	}
	if p := s.Properties; p.AvailabilityState != nil {
		switch *p.AvailabilityState {
		case armresourcehealth.AvailabilityStateValuesAvailable:
			obs.Health = model.HealthAvailable
		case armresourcehealth.AvailabilityStateValuesDegraded:
			obs.Health = model.HealthDegraded
		case armresourcehealth.AvailabilityStateValuesUnavailable:
			obs.Health = model.HealthUnavailable
		}
	}
	if s.Properties.Summary != nil {
		obs.Reason = *s.Properties.Summary
	}
	if s.Properties.ReasonType != nil && *s.Properties.ReasonType != "" {
		obs.Reason = strings.TrimSpace(*s.Properties.ReasonType + ": " + obs.Reason)
	}
	return obs, true
}

// heartbeatQuery reads the Azure Monitor Agent Heartbeat table.
const heartbeatQuery = `Heartbeat
| where TimeGenerated > datetime(%s)
| summarize LastHeartbeat = max(TimeGenerated) by rid = tolower(_ResourceId), Computer, Category`

// CollectHeartbeats implements providers.Adapter using the Log Analytics Heartbeat table
// populated by the Azure Monitor Agent. Returns ErrNotSupported when no workspace is
// configured for the account.
func (a *Adapter) CollectHeartbeats(ctx context.Context, acct providers.Account, since time.Time) ([]model.HeartbeatObservation, error) {
	cfg := parseConfig(acct)
	if len(cfg.WorkspaceIDs) == 0 {
		return nil, providers.ErrNotSupported
	}
	cred, err := a.credential(acct, cfg)
	if err != nil {
		return nil, err
	}
	client, err := azlogs.NewClient(cred, a.logsOptions(cfg))
	if err != nil {
		return nil, err
	}
	q := fmt.Sprintf(heartbeatQuery, since.UTC().Format(time.RFC3339))
	var out []model.HeartbeatObservation
	for _, ws := range cfg.WorkspaceIDs {
		resp, err := client.QueryWorkspace(ctx, ws, azlogs.QueryBody{Query: &q}, nil)
		if err != nil {
			return out, classify(err)
		}
		if resp.Error != nil {
			return out, fmt.Errorf("log analytics partial error: %s", resp.Error.Error())
		}
		for _, row := range tableRows(resp.Tables) {
			rid := asString(row["rid"])
			ts, err := time.Parse(time.RFC3339Nano, asString(row["LastHeartbeat"]))
			if rid == "" || err != nil {
				continue
			}
			out = append(out, model.HeartbeatObservation{
				ProviderResourceID: rid,
				Computer:           asString(row["Computer"]),
				LastHeartbeat:      ts.UTC(),
				Source:             "azure_monitor_agent:" + asString(row["Category"]),
			})
		}
	}
	return out, nil
}

func (a *Adapter) probeWorkspace(ctx context.Context, acct providers.Account, cfg accountConfig, ws string) error {
	cred, err := a.credential(acct, cfg)
	if err != nil {
		return err
	}
	client, err := azlogs.NewClient(cred, a.logsOptions(cfg))
	if err != nil {
		return err
	}
	q := "Heartbeat | take 1"
	ti := azlogs.NewTimeInterval(nowUTC().Add(-time.Hour), nowUTC())
	_, err = client.QueryWorkspace(ctx, ws, azlogs.QueryBody{Query: &q, Timespan: &ti}, nil)
	return classify(err)
}

func (a *Adapter) activityClient(acct providers.Account, cfg accountConfig, sub string) (*armmonitor.ActivityLogsClient, error) {
	cred, err := a.credential(acct, cfg)
	if err != nil {
		return nil, err
	}
	return armmonitor.NewActivityLogsClient(sub, cred, a.armOptions(cfg))
}

func (a *Adapter) probeActivityLog(ctx context.Context, acct providers.Account, cfg accountConfig, sub string) error {
	client, err := a.activityClient(acct, cfg, sub)
	if err != nil {
		return err
	}
	now := nowUTC()
	pager := client.NewListPager(activityFilter(now.Add(-time.Hour), now), nil)
	if pager.More() {
		_, err = pager.NextPage(ctx)
	}
	return classify(err)
}

func activityFilter(from, to time.Time) string {
	return fmt.Sprintf("eventTimestamp ge '%s' and eventTimestamp le '%s'", from.UTC().Format(time.RFC3339), to.UTC().Format(time.RFC3339))
}

// CollectEvents implements providers.Adapter using the Azure Activity Log. Administrative
// write/delete/action operations and Service Health / Resource Health events are kept;
// read operations are discarded.
func (a *Adapter) CollectEvents(ctx context.Context, acct providers.Account, since time.Time) ([]model.Event, error) {
	cfg := parseConfig(acct)
	subs, err := a.subscriptions(ctx, acct, cfg)
	if err != nil {
		return nil, err
	}
	now := nowUTC()
	var out []model.Event
	for _, sub := range subs {
		client, err := a.activityClient(acct, cfg, sub)
		if err != nil {
			return out, err
		}
		pager := client.NewListPager(activityFilter(since, now), &armmonitor.ActivityLogsClientListOptions{
			Select: toPtr("eventTimestamp,operationName,status,level,resourceId,caller,category,eventDataId,correlationId,description"),
		})
		for pages := 0; pager.More() && pages < 20; pages++ {
			page, err := pager.NextPage(ctx)
			if err != nil {
				return out, classify(err)
			}
			for _, e := range page.Value {
				if ev, ok := mapActivity(e); ok {
					out = append(out, ev)
				}
			}
		}
	}
	return out, nil
}

func lv(s *armmonitor.LocalizableString) string {
	if s == nil {
		return ""
	}
	if s.LocalizedValue != nil && *s.LocalizedValue != "" {
		return *s.LocalizedValue
	}
	if s.Value != nil {
		return *s.Value
	}
	return ""
}

func mapActivity(e *armmonitor.EventData) (model.Event, bool) {
	if e == nil || e.EventTimestamp == nil || e.EventDataID == nil {
		return model.Event{}, false
	}
	category := ""
	if e.Category != nil && e.Category.Value != nil {
		category = *e.Category.Value
	}
	op := ""
	if e.OperationName != nil && e.OperationName.Value != nil {
		op = strings.ToLower(*e.OperationName.Value)
	}
	if category == "Administrative" && !(strings.HasSuffix(op, "/write") || strings.HasSuffix(op, "/delete") || strings.HasSuffix(op, "/action")) {
		return model.Event{}, false
	}
	sev := "info"
	if e.Level != nil {
		switch *e.Level {
		case armmonitor.EventLevelCritical:
			sev = "critical"
		case armmonitor.EventLevelError:
			sev = "error"
		case armmonitor.EventLevelWarning:
			sev = "warning"
		}
	}
	rid := ""
	if e.ResourceID != nil {
		rid = strings.ToLower(*e.ResourceID)
	}
	caller := ""
	if e.Caller != nil {
		caller = *e.Caller
	}
	msg := fmt.Sprintf("%s: %s", lv(e.OperationName), lv(e.Status))
	if caller != "" {
		msg += " by " + caller
	}
	details := map[string]any{"category": category, "operation": op, "status": lv(e.Status)}
	if e.CorrelationID != nil {
		details["correlation_id"] = *e.CorrelationID
	}
	if e.Description != nil && *e.Description != "" {
		details["description"] = *e.Description
	}
	return model.Event{
		ProviderResourceID: rid,
		ExternalID:         *e.EventDataID,
		Kind:               "azure_activity:" + strings.ToLower(category),
		Severity:           sev,
		Message:            msg,
		At:                 e.EventTimestamp.UTC(),
		Details:            details,
	}, true
}
