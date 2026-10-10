package agent

import (
	"context"

	"github.com/harsundeepwathan/az400/go/pkg/telemetry"
)

// ServiceSource reads OS service state. Implementations: systemd (Linux) and the
// Windows Service Control Manager. Both are read-only: the agent never starts, stops
// or restarts services.
type ServiceSource interface {
	// Get returns the state of the named services. Unknown names are reported with
	// state "unknown" so the server can flag a typo or missing service.
	Get(ctx context.Context, names []string) ([]telemetry.Service, error)
	// Discover lists all services on the host (inventory, sent infrequently).
	Discover(ctx context.Context) ([]telemetry.Service, error)
}
