package health

import (
	"time"

	"github.com/harsundeepwathan/az400/go/internal/model"
)

// Interval is a period during which a resource was in one operational state.
type Interval struct {
	State model.OperationalState
	Start time.Time
	End   time.Time // zero = still open
}

// AvailabilityPolicy defines how states count towards availability. The default policy
// (documented in docs/STATE_MODEL.md#availability):
//
//	available   = healthy, warning, critical
//	unavailable = down
//	excluded    = maintenance, stopped, unknown, no_data
//
// CriticalIsDown moves critical into "unavailable" for stricter SLOs.
type AvailabilityPolicy struct {
	CriticalIsDown bool
	StoppedIsDown  bool
}

// Availability is the result of an availability calculation.
type Availability struct {
	Period      time.Duration `json:"period_seconds"`
	Available   time.Duration `json:"available_seconds"`
	Unavailable time.Duration `json:"unavailable_seconds"`
	Excluded    time.Duration `json:"excluded_seconds"`
	// Percent is available / (available + unavailable) * 100; nil when nothing was observed.
	Percent *float64 `json:"percent"`
	// Coverage is the share of the period with an evaluable (non-excluded) state.
	Coverage float64 `json:"coverage"`
}

// ComputeAvailability computes availability over [from, to). Time before the first
// interval and gaps between intervals count as excluded (no observation).
func ComputeAvailability(intervals []Interval, from, to time.Time, p AvailabilityPolicy) Availability {
	a := Availability{Period: to.Sub(from)}
	var covered time.Duration
	for _, iv := range intervals {
		start, end := iv.Start, iv.End
		if end.IsZero() || end.After(to) {
			end = to
		}
		if start.Before(from) {
			start = from
		}
		if !end.After(start) {
			continue
		}
		d := end.Sub(start)
		covered += d
		switch classify(iv.State, p) {
		case 1:
			a.Available += d
		case -1:
			a.Unavailable += d
		default:
			a.Excluded += d
		}
	}
	if gap := a.Period - covered; gap > 0 {
		a.Excluded += gap
	}
	if obs := a.Available + a.Unavailable; obs > 0 {
		pct := float64(a.Available) / float64(obs) * 100
		a.Percent = &pct
		if a.Period > 0 {
			a.Coverage = float64(obs) / float64(a.Period)
		}
	}
	return a
}

func classify(s model.OperationalState, p AvailabilityPolicy) int {
	switch s {
	case model.StateHealthy, model.StateWarning:
		return 1
	case model.StateCritical:
		if p.CriticalIsDown {
			return -1
		}
		return 1
	case model.StateDown:
		return -1
	case model.StateStopped:
		if p.StoppedIsDown {
			return -1
		}
		return 0
	default:
		return 0
	}
}
