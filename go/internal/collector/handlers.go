package collector

import (
	"context"
	"encoding/json"
	"strings"
	"time"

	"github.com/harsundeepwathan/az400/go/internal/model"
	"github.com/harsundeepwathan/az400/go/internal/providers"
	"github.com/harsundeepwathan/az400/go/internal/tsdb"
)

func metricSource(p model.Provider) string {
	switch p {
	case model.ProviderAzure:
		return "azure_monitor"
	case model.ProviderDigitalOcean:
		return "do_monitoring"
	case model.ProviderAlibaba:
		return "cloudmonitor"
	case model.ProviderDemo:
		return "demo"
	}
	return string(p)
}

// runDiscovery upserts discovered resources. Resources missing from a *complete*
// discovery are soft-deleted; a failed discovery never deletes anything.
func (s *Scheduler) runDiscovery(ctx context.Context, ad providers.Adapter, acct providers.Account) (RunResult, error) {
	found, err := ad.Discover(ctx, acct)
	if err != nil {
		return RunResult{}, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return RunResult{}, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	now := s.now().UTC()
	ids := map[string]string{} // provider id -> resource id
	// Resources the operator deselected during onboarding are inventoried but not monitored.
	excluded := map[string]bool{}
	if list, ok := acct.Config["excluded_resource_ids"].([]any); ok {
		for _, x := range list {
			if id, ok := x.(string); ok {
				excluded[id] = true
			}
		}
	}
	for _, d := range found {
		cfg, _ := json.Marshal(d.Config)
		var id string
		var osType *string
		if d.OSType != "" {
			osType = &d.OSType
		}
		err := tx.QueryRow(ctx, `
			INSERT INTO resources(org_id, cloud_account_id, provider, provider_resource_id, external_account_id, name,
				resource_type, native_type, region, resource_group, environment, os_type, os_name, config,
				provider_state_raw, power_state, discovered_at, last_seen_in_discovery, monitoring_enabled)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$17,$18)
			ON CONFLICT (org_id, provider, provider_resource_id) DO UPDATE SET
				cloud_account_id = EXCLUDED.cloud_account_id, external_account_id = EXCLUDED.external_account_id,
				name = EXCLUDED.name, resource_type = EXCLUDED.resource_type, native_type = EXCLUDED.native_type,
				region = EXCLUDED.region, resource_group = EXCLUDED.resource_group, environment = EXCLUDED.environment,
				os_type = coalesce(EXCLUDED.os_type, resources.os_type), os_name = coalesce(nullif(EXCLUDED.os_name,''), resources.os_name),
				config = resources.config || EXCLUDED.config, provider_state_raw = EXCLUDED.provider_state_raw,
				power_state = EXCLUDED.power_state, last_seen_in_discovery = EXCLUDED.last_seen_in_discovery, deleted_at = NULL
			RETURNING id`,
			acct.OrgID, acct.ID, string(ad.Provider()), d.ProviderResourceID, d.ExternalAccountID, d.Name,
			string(d.Type), d.NativeType, d.Region, d.ResourceGroup, nullIfEmpty(d.Environment()), osType, d.OSName, cfg,
			d.ProviderStateRaw, string(d.PowerState), now, !excluded[d.ProviderResourceID]).Scan(&id)
		if err != nil {
			return RunResult{}, err
		}
		ids[d.ProviderResourceID] = id
		if _, err := tx.Exec(ctx, `DELETE FROM resource_tags WHERE resource_id=$1`, id); err != nil {
			return RunResult{}, err
		}
		for k, v := range d.Tags {
			if _, err := tx.Exec(ctx, `INSERT INTO resource_tags(org_id, resource_id, key, value) VALUES ($1,$2,$3,$4)`,
				acct.OrgID, id, truncate(k, 512), truncate(v, 1024)); err != nil {
				return RunResult{}, err
			}
		}
	}
	// Relations are rebuilt from discovery each run.
	if _, err := tx.Exec(ctx, `DELETE FROM resource_relations WHERE org_id=$1 AND source='discovery'
		AND from_resource_id IN (SELECT id FROM resources WHERE cloud_account_id=$2)`, acct.OrgID, acct.ID); err != nil {
		return RunResult{}, err
	}
	for _, d := range found {
		for _, r := range d.Relations {
			from, to := ids[d.ProviderResourceID], ids[r.ToProviderResourceID]
			if from == "" || to == "" {
				continue
			}
			if _, err := tx.Exec(ctx, `INSERT INTO resource_relations(org_id, from_resource_id, to_resource_id, kind, source)
				VALUES ($1,$2,$3,$4,'discovery') ON CONFLICT DO NOTHING`, acct.OrgID, from, to, r.Kind); err != nil {
				return RunResult{}, err
			}
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE resources SET deleted_at = $3
		WHERE org_id=$1 AND cloud_account_id=$2 AND deleted_at IS NULL AND (last_seen_in_discovery IS NULL OR last_seen_in_discovery < $3)`,
		acct.OrgID, acct.ID, now); err != nil {
		return RunResult{}, err
	}
	if _, err := tx.Exec(ctx, `UPDATE cloud_accounts SET last_discovery_at=$2 WHERE id=$1`, acct.ID, now); err != nil {
		return RunResult{}, err
	}
	return RunResult{Items: len(found)}, tx.Commit(ctx)
}

func (s *Scheduler) loadRefs(ctx context.Context, acct providers.Account) ([]model.ResourceRef, error) {
	rows, err := s.pool.Query(ctx, `SELECT id, provider_resource_id, resource_type, coalesce(region,''), coalesce(os_type,''), power_state, config
		FROM resources WHERE org_id=$1 AND cloud_account_id=$2 AND deleted_at IS NULL AND monitoring_enabled`, acct.OrgID, acct.ID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []model.ResourceRef
	for rows.Next() {
		var r model.ResourceRef
		var rt, ps string
		var cfg []byte
		if err := rows.Scan(&r.ID, &r.ProviderResourceID, &rt, &r.Region, &r.OSType, &ps, &cfg); err != nil {
			return nil, err
		}
		r.Type, r.PowerState = model.ResourceType(rt), model.PowerState(ps)
		_ = json.Unmarshal(cfg, &r.Config)
		out = append(out, r)
	}
	return out, rows.Err()
}

func (s *Scheduler) runMetrics(ctx context.Context, ad providers.Adapter, acct providers.Account) (RunResult, error) {
	refs, err := s.loadRefs(ctx, acct)
	if err != nil || len(refs) == 0 {
		return RunResult{}, err
	}
	now := s.now().UTC()
	// Overlapping window: provider metrics land late; idempotent inserts absorb overlap.
	res, cerr := ad.CollectMetrics(ctx, acct, refs, now.Add(-15*time.Minute), now)
	items := 0
	src := metricSource(ad.Provider())
	if res != nil {
		for id, samples := range res.Samples {
			n, err := tsdb.WriteSamples(ctx, s.pool, acct.OrgID, id, src, samples, now)
			if err != nil {
				return RunResult{Items: items}, err
			}
			items += n
		}
		for _, ref := range refs {
			gaps := res.Unavailable[ref.ID]
			if gaps == nil {
				gaps = map[string]string{}
			}
			b, _ := json.Marshal(gaps)
			if _, err := s.pool.Exec(ctx, `UPDATE resources SET metric_gaps=$2 WHERE id=$1`, ref.ID, b); err != nil {
				return RunResult{Items: items}, err
			}
		}
	}
	if cerr != nil {
		return RunResult{Items: items, Partial: items > 0}, cerr
	}
	return RunResult{Items: items}, nil
}

func (s *Scheduler) runHealth(ctx context.Context, ad providers.Adapter, acct providers.Account) (RunResult, error) {
	refs, err := s.loadRefs(ctx, acct)
	if err != nil || len(refs) == 0 {
		return RunResult{}, err
	}
	obs, err := ad.CollectHealth(ctx, acct, refs)
	if err != nil {
		return RunResult{}, err
	}
	for _, o := range obs {
		if _, err := s.pool.Exec(ctx, `UPDATE resources SET provider_health=$3, provider_health_reason=$4, provider_health_at=$5
			WHERE org_id=$1 AND cloud_account_id=$2 AND provider_resource_id=$6`,
			acct.OrgID, acct.ID, string(o.Health), truncate(o.Reason, 1000), o.ObservedAt, o.ProviderResourceID); err != nil {
			return RunResult{}, err
		}
	}
	return RunResult{Items: len(obs)}, nil
}

func (s *Scheduler) runHeartbeat(ctx context.Context, ad providers.Adapter, acct providers.Account) (RunResult, error) {
	hbs, err := ad.CollectHeartbeats(ctx, acct, s.now().Add(-time.Hour))
	if err != nil {
		return RunResult{}, err
	}
	for _, h := range hbs {
		if _, err := s.pool.Exec(ctx, `UPDATE resources SET guest_heartbeat_at = GREATEST(coalesce(guest_heartbeat_at,'epoch'), $3),
			guest_heartbeat_source=$4 WHERE org_id=$1 AND cloud_account_id=$2 AND provider_resource_id=$5`,
			acct.OrgID, acct.ID, h.LastHeartbeat, h.Source, strings.ToLower(h.ProviderResourceID)); err != nil {
			return RunResult{}, err
		}
	}
	return RunResult{Items: len(hbs)}, nil
}

func (s *Scheduler) runEvents(ctx context.Context, ad providers.Adapter, acct providers.Account, since time.Time) (RunResult, error) {
	evs, err := ad.CollectEvents(ctx, acct, since)
	if err != nil {
		return RunResult{}, err
	}
	n := 0
	for _, e := range evs {
		details, _ := json.Marshal(e.Details)
		tag, err := s.pool.Exec(ctx, `INSERT INTO infra_events(org_id, resource_id, source, kind, severity, message, at, external_id, details)
			VALUES ($1, (SELECT id FROM resources WHERE org_id=$1 AND cloud_account_id=$2 AND provider_resource_id=$3), $4, $5, $6, $7, $8, $9, $10)
			ON CONFLICT (org_id, source, external_id) DO NOTHING`,
			acct.OrgID, acct.ID, strings.ToLower(e.ProviderResourceID), string(ad.Provider()), e.Kind, e.Severity, truncate(e.Message, 2000), e.At, e.ExternalID, details)
		if err != nil {
			return RunResult{Items: n}, err
		}
		n += int(tag.RowsAffected())
	}
	return RunResult{Items: n}, nil
}

func nullIfEmpty(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}
