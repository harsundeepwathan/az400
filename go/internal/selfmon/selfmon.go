// Package selfmon exposes the platform's own health: Prometheus metrics for every
// pipeline stage plus a database-backed instance heartbeat so the UI can show
// "Monitoring Degraded" when a collector or the ingest path stops working.
package selfmon

import (
	"context"
	"encoding/json"
	"log/slog"
	"os"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

var (
	CollectorRuns = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "skywatch_collector_runs_total", Help: "Collection job runs by kind and status."}, []string{"kind", "status"})
	CollectorDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name: "skywatch_collector_run_seconds", Help: "Collection job duration.", Buckets: prometheus.ExponentialBuckets(0.1, 2, 12)}, []string{"kind"})
	ProviderCalls = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "skywatch_provider_api_calls_total", Help: "Provider API attempts by job kind."}, []string{"kind"})
	ProviderThrottled = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "skywatch_provider_api_throttled_total", Help: "Provider API 429 responses by job kind."}, []string{"kind"})
	IngestBatches = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "skywatch_ingest_batches_total", Help: "Agent telemetry batches by outcome."}, []string{"outcome"})
	IngestSamples = promauto.NewCounter(prometheus.CounterOpts{
		Name: "skywatch_ingest_samples_total", Help: "Agent metric samples accepted."})
	IngestLatency = promauto.NewHistogram(prometheus.HistogramOpts{
		Name: "skywatch_ingest_batch_seconds", Help: "Time to persist one agent batch.", Buckets: prometheus.DefBuckets})
	EvaluatorCycles = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "skywatch_evaluator_cycles_total", Help: "Evaluator cycles by outcome."}, []string{"outcome"})
	EvaluatorDuration = promauto.NewHistogram(prometheus.HistogramOpts{
		Name: "skywatch_evaluator_cycle_seconds", Help: "Evaluator cycle duration.", Buckets: prometheus.DefBuckets})
	NotificationsSent = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "skywatch_notifications_total", Help: "Notification deliveries by channel kind and outcome."}, []string{"kind", "outcome"})
	ProbeRuns = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "skywatch_probe_checks_total", Help: "Synthetic checks executed by kind and result."}, []string{"kind", "result"})
	QueueDepth = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Name: "skywatch_queue_depth", Help: "Due-but-unprocessed work items by queue."}, []string{"queue"})
)

// Stats is published with each instance heartbeat.
type Stats struct {
	DueJobs           int64 `json:"due_jobs"`
	PendingDeliveries int64 `json:"pending_deliveries"`
	DueSynthetic      int64 `json:"due_synthetic"`
	DBLatencyMs       int64 `json:"db_latency_ms"`
}

// Heartbeat periodically records this instance in platform_instances and samples
// queue depths and database latency.
func Heartbeat(ctx context.Context, pool *pgxpool.Pool, instanceID, version string, roles []string, log *slog.Logger) {
	host, _ := os.Hostname()
	started := time.Now()
	tick := time.NewTicker(15 * time.Second)
	defer tick.Stop()
	for {
		var st Stats
		t0 := time.Now()
		err := pool.QueryRow(ctx, `SELECT
			(SELECT count(*) FROM collection_jobs WHERE next_run_at < now() - interval '1 minute' AND lease_owner IS NULL),
			(SELECT count(*) FROM notification_deliveries WHERE status='pending' AND next_attempt_at < now()),
			(SELECT count(*) FROM synthetic_checks WHERE enabled AND next_run_at < now() - interval '1 minute')`).
			Scan(&st.DueJobs, &st.PendingDeliveries, &st.DueSynthetic)
		st.DBLatencyMs = time.Since(t0).Milliseconds()
		if err == nil {
			QueueDepth.WithLabelValues("collection_jobs").Set(float64(st.DueJobs))
			QueueDepth.WithLabelValues("notifications").Set(float64(st.PendingDeliveries))
			QueueDepth.WithLabelValues("synthetic").Set(float64(st.DueSynthetic))
			b, _ := json.Marshal(st)
			_, err = pool.Exec(ctx, `INSERT INTO platform_instances(instance_id, roles, version, hostname, started_at, last_heartbeat, stats)
				VALUES ($1,$2,$3,$4,$5,now(),$6)
				ON CONFLICT (instance_id) DO UPDATE SET roles=EXCLUDED.roles, version=EXCLUDED.version,
					last_heartbeat=now(), stats=EXCLUDED.stats`, instanceID, roles, version, host, started, b)
		}
		if err != nil && ctx.Err() == nil {
			log.Warn("platform heartbeat failed", "err", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}
