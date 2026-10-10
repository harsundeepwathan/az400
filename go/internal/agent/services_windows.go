//go:build windows

package agent

import (
	"context"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/svc"
	"golang.org/x/sys/windows/svc/mgr"

	"github.com/harsundeepwathan/az400/go/pkg/telemetry"
)

// scmSource reads the Windows Service Control Manager with read-only access rights.
type scmSource struct{}

// NewServiceSource returns the platform service source.
func NewServiceSource() ServiceSource { return scmSource{} }

func mapWinState(s svc.State) string {
	switch s {
	case svc.Running:
		return "running"
	case svc.Stopped:
		return "stopped"
	case svc.StartPending, svc.ContinuePending:
		return "starting"
	case svc.StopPending, svc.PausePending, svc.Paused:
		return "stopping"
	}
	return "unknown"
}

func startType(t uint32, delayed bool) string {
	switch t {
	case mgr.StartAutomatic:
		if delayed {
			return "automatic_delayed"
		}
		return "automatic"
	case mgr.StartManual:
		return "manual"
	case mgr.StartDisabled:
		return "disabled"
	}
	return "other"
}

func connect() (*mgr.Mgr, error) {
	h, err := windows.OpenSCManager(nil, nil, windows.SC_MANAGER_CONNECT|windows.SC_MANAGER_ENUMERATE_SERVICE)
	if err != nil {
		return nil, err
	}
	return &mgr.Mgr{Handle: h}, nil
}

func query(m *mgr.Mgr, name string) telemetry.Service {
	out := telemetry.Service{Platform: "windows", Name: name, State: "unknown"}
	h, err := windows.OpenService(m.Handle, windows.StringToUTF16Ptr(name), windows.SERVICE_QUERY_STATUS|windows.SERVICE_QUERY_CONFIG)
	if err != nil {
		return out
	}
	s := &mgr.Service{Name: name, Handle: h}
	defer s.Close()
	if st, err := s.Query(); err == nil {
		out.State = mapWinState(st.State)
		out.SubState = out.State
		out.PID = int(st.ProcessId)
	}
	if cfg, err := s.Config(); err == nil {
		out.DisplayName = cfg.DisplayName
		out.StartupType = startType(cfg.StartType, cfg.DelayedAutoStart)
	}
	return out
}

func (scmSource) Get(_ context.Context, names []string) ([]telemetry.Service, error) {
	m, err := connect()
	if err != nil {
		return nil, err
	}
	defer m.Disconnect()
	out := make([]telemetry.Service, 0, len(names))
	for _, n := range names {
		out = append(out, query(m, n))
	}
	return out, nil
}

func (scmSource) Discover(_ context.Context) ([]telemetry.Service, error) {
	m, err := connect()
	if err != nil {
		return nil, err
	}
	defer m.Disconnect()
	names, err := m.ListServices()
	if err != nil {
		return nil, err
	}
	var out []telemetry.Service
	for _, n := range names {
		out = append(out, query(m, n))
		if len(out) >= telemetry.MaxServices {
			break
		}
	}
	return out, nil
}
