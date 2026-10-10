package agent

import (
	"context"
	"testing"

	"github.com/harsundeepwathan/az400/go/pkg/telemetry"
)

func TestQueueBoundedDropsOldest(t *testing.T) {
	q := NewQueue(2)
	for _, id := range []string{"a", "b", "c"} {
		q.Push(telemetry.Batch{BatchID: id})
	}
	if q.Len() != 2 || q.Dropped() != 1 {
		t.Fatalf("len=%d dropped=%d", q.Len(), q.Dropped())
	}
	if b, _ := q.Peek(); b.BatchID != "b" {
		t.Fatalf("oldest kept should be b, got %s", b.BatchID)
	}
	q.Pop("x") // wrong id: no-op
	q.Pop("b")
	if b, _ := q.Peek(); b.BatchID != "c" {
		t.Fatal("pop failed")
	}
}

func TestCollectorProducesHostMetrics(t *testing.T) {
	c := NewCollector(nil)
	ctx := context.Background()
	c.Collect(ctx)
	samples, _ := c.Collect(ctx)
	got := map[string]bool{}
	for _, s := range samples {
		got[s.Metric] = true
	}
	for _, m := range []string{"memory.utilization", "memory.total_bytes"} {
		if !got[m] {
			t.Errorf("missing %s", m)
		}
	}
	b := telemetry.Batch{Version: "1", BatchID: "6f1c7b4e-1d2a-4c55-9e0e-2c1f7b3a9d10", Metrics: samples}
	if err := b.Validate(); err != nil {
		t.Fatalf("collected samples must satisfy the contract: %v", err)
	}
}

func TestConfigRequiresHTTPS(t *testing.T) {
	if (&Config{ServerURL: "http://x"}).Validate() == nil {
		t.Fatal("plain http must be refused by default")
	}
	if (&Config{ServerURL: "http://x", AllowInsecureHTTP: true}).Validate() != nil {
		t.Fatal("explicit dev opt-in should allow http")
	}
}
