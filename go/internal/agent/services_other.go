//go:build !linux && !windows

package agent

import (
	"context"
	"errors"

	"github.com/harsundeepwathan/az400/go/pkg/telemetry"
)

type noServices struct{}

// NewServiceSource returns a source that reports service monitoring as unsupported.
func NewServiceSource() ServiceSource { return noServices{} }

var errUnsupported = errors.New("service monitoring is supported on Linux (systemd) and Windows only")

func (noServices) Get(context.Context, []string) ([]telemetry.Service, error) {
	return nil, errUnsupported
}
func (noServices) Discover(context.Context) ([]telemetry.Service, error) { return nil, errUnsupported }
