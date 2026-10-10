//go:build linux

package agent

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/harsundeepwathan/az400/go/pkg/telemetry"
)

// systemdSource queries systemd through systemctl with fixed arguments (no shell).
type systemdSource struct{}

// NewServiceSource returns the platform service source.
func NewServiceSource() ServiceSource { return systemdSource{} }

func systemctl(ctx context.Context, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	path, err := exec.LookPath("systemctl")
	if err != nil {
		return nil, errors.New("systemctl not found: host is not managed by systemd")
	}
	cmd := exec.CommandContext(ctx, path, args...)
	cmd.Env = []string{"LC_ALL=C", "SYSTEMD_PAGER="}
	out, err := cmd.Output()
	var ee *exec.ExitError
	if errors.As(err, &ee) && len(ee.Stderr) > 0 {
		// e.g. "System has not been booted with systemd as init system (PID 1)."
		msg := strings.TrimSpace(strings.SplitN(string(ee.Stderr), "\n", 2)[0])
		return out, errors.New("systemctl: " + msg)
	}
	return out, err
}

// MapSystemdState maps ActiveState to the contract's service states.
func MapSystemdState(active, load string) string {
	if load == "not-found" {
		return "unknown"
	}
	switch active {
	case "active", "reloading":
		return "running"
	case "inactive":
		return "stopped"
	case "failed":
		return "failed"
	case "activating":
		return "starting"
	case "deactivating":
		return "stopping"
	}
	return "unknown"
}

func unitName(n string) string {
	if strings.Contains(n, ".") {
		return n
	}
	return n + ".service"
}

// ParseSystemctlShow parses `systemctl show` output for several units (blank-line separated).
func ParseSystemctlShow(out []byte) []telemetry.Service {
	var res []telemetry.Service
	for _, block := range bytes.Split(out, []byte("\n\n")) {
		props := map[string]string{}
		sc := bufio.NewScanner(bytes.NewReader(block))
		for sc.Scan() {
			if k, v, ok := strings.Cut(sc.Text(), "="); ok {
				props[k] = v
			}
		}
		if props["Id"] == "" {
			continue
		}
		pid, _ := strconv.Atoi(props["MainPID"])
		restarts, _ := strconv.Atoi(props["NRestarts"])
		res = append(res, telemetry.Service{
			Platform: "systemd", Name: props["Id"], DisplayName: props["Description"],
			State: MapSystemdState(props["ActiveState"], props["LoadState"]), SubState: props["SubState"],
			StartupType: props["UnitFileState"], PID: pid, Restarts: restarts,
		})
	}
	return res
}

func (systemdSource) Get(ctx context.Context, names []string) ([]telemetry.Service, error) {
	if len(names) == 0 {
		return nil, nil
	}
	args := []string{"show", "--no-pager", "--property=Id,Description,LoadState,ActiveState,SubState,MainPID,NRestarts,UnitFileState"}
	for _, n := range names {
		if strings.ContainsAny(n, " \t\n;|&$`") || strings.HasPrefix(n, "-") {
			continue // names come from the server; never pass anything option- or shell-like
		}
		args = append(args, unitName(n))
	}
	out, err := systemctl(ctx, args...)
	if err != nil {
		return nil, err
	}
	svcs := ParseSystemctlShow(out)
	// Report under the name the operator configured so the server can match it.
	for i := range svcs {
		for _, n := range names {
			if unitName(n) == svcs[i].Name {
				svcs[i].Name = n
			}
		}
	}
	return svcs, nil
}

func (systemdSource) Discover(ctx context.Context) ([]telemetry.Service, error) {
	out, err := systemctl(ctx, "list-units", "--type=service", "--all", "--no-legend", "--plain", "--no-pager")
	if err != nil {
		return nil, err
	}
	var res []telemetry.Service
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) < 4 {
			continue
		}
		res = append(res, telemetry.Service{Platform: "systemd", Name: f[0], State: MapSystemdState(f[2], f[1]), SubState: f[3],
			DisplayName: strings.Join(f[4:], " ")})
		if len(res) >= telemetry.MaxServices {
			break
		}
	}
	return res, nil
}
