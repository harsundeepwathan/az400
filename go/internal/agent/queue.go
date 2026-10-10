package agent

import (
	"sync"

	"github.com/harsundeepwathan/az400/go/pkg/telemetry"
)

// Queue is a bounded FIFO of telemetry batches. When full, the oldest batch is dropped
// and counted so the server can see data loss (AgentHealth.DroppedBatches). Heartbeats
// stay current during long outages because the newest data is always kept.
type Queue struct {
	mu      sync.Mutex
	items   []telemetry.Batch
	max     int
	dropped int64
}

// NewQueue creates a queue holding at most max batches.
func NewQueue(max int) *Queue { return &Queue{max: max} }

// Push appends a batch, evicting the oldest when full.
func (q *Queue) Push(b telemetry.Batch) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if len(q.items) >= q.max {
		q.items = q.items[1:]
		q.dropped++
	}
	q.items = append(q.items, b)
}

// Peek returns the oldest batch without removing it.
func (q *Queue) Peek() (telemetry.Batch, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if len(q.items) == 0 {
		return telemetry.Batch{}, false
	}
	return q.items[0], true
}

// Pop removes the oldest batch if it has the given ID.
func (q *Queue) Pop(id string) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if len(q.items) > 0 && q.items[0].BatchID == id {
		q.items = q.items[1:]
	}
}

// Len returns the current depth.
func (q *Queue) Len() int {
	q.mu.Lock()
	defer q.mu.Unlock()
	return len(q.items)
}

// Dropped returns the number of evicted batches.
func (q *Queue) Dropped() int64 {
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.dropped
}
