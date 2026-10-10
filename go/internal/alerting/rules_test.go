package alerting

import (
	"testing"
	"time"

	"github.com/harsundeepwathan/az400/go/internal/model"
)

var t0 = time.Date(2026, 10, 10, 12, 0, 0, 0, time.UTC)

func series(start time.Time, vals ...float64) []Point {
	out := make([]Point, len(vals))
	for i, v := range vals {
		out[i] = Point{TS: start.Add(time.Duration(i) * time.Minute), Value: v}
	}
	return out
}

func cpuRule() Rule {
	rec := 80.0
	return Rule{ID: "r1", Name: "CPU high", Kind: KindMetric, Metric: "cpu.utilization", Operator: ">",
		Threshold: 85, RecoveryThreshold: &rec, For: 5 * time.Minute, Consecutive: 1, Severity: model.SeverityWarning}
}

func TestEvaluateSeriesSustainedBreach(t *testing.T) {
	r := cpuRule()
	// 5 consecutive one-minute buckets above 85 => sustained for 5 minutes.
	pts := series(t0, 50, 90, 91, 92, 93, 94)
	o := EvaluateSeries(r, pts, t0.Add(6*time.Minute), 15*time.Minute)
	if !o.Breaching || !o.Sustained {
		t.Fatalf("expected sustained breach: %+v", o)
	}
	if !o.BreachSince.Equal(t0.Add(time.Minute)) {
		t.Errorf("BreachSince = %v", o.BreachSince)
	}
	// 4 buckets is not enough.
	o = EvaluateSeries(r, series(t0, 50, 50, 91, 92, 93, 94), t0.Add(6*time.Minute), 15*time.Minute)
	if !o.Breaching || o.Sustained {
		t.Fatalf("4 minutes should be pending only: %+v", o)
	}
}

func TestEvaluateSeriesGapBreaksRun(t *testing.T) {
	r := cpuRule()
	pts := []Point{{t0, 95}, {t0.Add(time.Minute), 95}, {t0.Add(10 * time.Minute), 95}, {t0.Add(11 * time.Minute), 95}}
	o := EvaluateSeries(r, pts, t0.Add(12*time.Minute), 15*time.Minute)
	if o.Sustained {
		t.Fatal("a data gap must not count towards the 'for' duration")
	}
}

func TestEvaluateSeriesStaleData(t *testing.T) {
	o := EvaluateSeries(cpuRule(), series(t0, 99, 99, 99, 99, 99, 99), t0.Add(time.Hour), 15*time.Minute)
	if o.HasData {
		t.Fatal("stale data must be treated as no data")
	}
}

func TestLatencyTolerantEvaluation(t *testing.T) {
	// Azure metrics often lag by several minutes; evaluation uses data timestamps.
	o := EvaluateSeries(cpuRule(), series(t0, 96, 96, 96, 96, 96), t0.Add(12*time.Minute), 15*time.Minute)
	if !o.Sustained {
		t.Fatal("lagging but complete data should still fire")
	}
}

func TestStateMachineLifecycleWithHysteresis(t *testing.T) {
	r := cpuRule()
	inst := Instance{}
	now := t0

	step := func(vals ...float64) *Transition {
		now = now.Add(time.Minute)
		var tr *Transition
		inst, tr = Step(r, inst, EvaluateSeries(r, series(now.Add(-time.Duration(len(vals)-1)*time.Minute), vals...), now, 15*time.Minute), now)
		return tr
	}

	if tr := step(90); tr == nil || tr.To != StatePending {
		t.Fatalf("expected pending, got %+v / %s", tr, inst.State)
	}
	if tr := step(90, 91, 92, 93, 94); tr == nil || tr.To != StateFiring {
		t.Fatalf("expected firing, got %+v / %s", tr, inst.State)
	}
	// 83 is below the 85 threshold but above the 80 recovery threshold: stay firing.
	if tr := step(83); tr != nil || inst.State != StateFiring {
		t.Fatalf("hysteresis violated: %+v / %s", tr, inst.State)
	}
	if tr := step(79); tr == nil || tr.To != StateResolved {
		t.Fatalf("expected resolved, got %+v / %s", tr, inst.State)
	}
	// No data holds state.
	if _, tr := Step(r, inst, Observation{}, now); tr != nil {
		t.Fatal("no data must not transition")
	}
	// Pending that recovers returns to normal without firing.
	inst = Instance{}
	step(90)
	if tr := step(70); tr == nil || tr.To != StateNormal {
		t.Fatalf("pending should drop back to normal: %+v", tr)
	}
}

func TestImmediateRuleFiresOnFirstSample(t *testing.T) {
	r := Rule{Name: "Disk", Metric: "disk.utilization", Operator: ">", Threshold: 90, For: 0, Consecutive: 1, Severity: model.SeverityCritical}
	inst, tr := Step(r, Instance{}, EvaluateSeries(r, []Point{{t0, 93.4}}, t0, 15*time.Minute), t0)
	if tr == nil || inst.State != StateFiring {
		t.Fatalf("for=0 rule should fire immediately: %+v", inst)
	}
	if tr.Message != "Disk: value 93.4% > threshold 90.0%" {
		t.Errorf("message = %q", tr.Message)
	}
}

func TestConsecutiveRequirement(t *testing.T) {
	r := Rule{Name: "x", Metric: "m", Operator: ">=", Threshold: 1, For: 0, Consecutive: 3}
	if o := EvaluateSeries(r, series(t0, 1, 1), t0.Add(time.Minute), time.Hour); o.Sustained {
		t.Fatal("2 of 3 consecutive should not be sustained")
	}
	if o := EvaluateSeries(r, series(t0, 1, 1, 1), t0.Add(2*time.Minute), time.Hour); !o.Sustained {
		t.Fatal("3 consecutive should be sustained")
	}
}

func TestScopeAndExclusions(t *testing.T) {
	r := Rule{
		Scope:      Scope{Providers: []string{"azure"}, Environments: []string{"production"}, Tags: map[string]string{"team": "*"}},
		Exclusions: Exclusions{OSTypes: []string{"windows"}, Series: []string{"mount=/mnt/*"}},
	}
	base := Subject{ID: "a", Provider: "azure", Environment: "production", OSType: "linux", Tags: map[string]string{"team": "web"}}
	if !r.Matches(base) {
		t.Fatal("should match")
	}
	win := base
	win.OSType = "windows"
	if r.Matches(win) {
		t.Error("windows excluded")
	}
	noTag := base
	noTag.Tags = nil
	if r.Matches(noTag) {
		t.Error("tag required")
	}
	if r.SeriesIncluded("mount=/mnt/scratch") || !r.SeriesIncluded("mount=/var") {
		t.Error("series exclusion glob")
	}
}
