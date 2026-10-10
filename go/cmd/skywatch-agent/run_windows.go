//go:build windows

package main

import (
	"context"
	"log/slog"

	"golang.org/x/sys/windows/svc"

	"github.com/harsundeepwathan/az400/go/internal/agent"
)

// run starts under the Service Control Manager when installed as a Windows service
// (sc.exe create SkywatchAgent binPath= "...\skywatch-agent.exe run"), otherwise in
// the foreground.
func run(dir string, log *slog.Logger) error {
	isSvc, err := svc.IsWindowsService()
	if err != nil || !isSvc {
		return runForeground(dir, log)
	}
	return svc.Run("SkywatchAgent", &handler{dir: dir, log: log})
}

type handler struct {
	dir string
	log *slog.Logger
}

func (h *handler) Execute(_ []string, req <-chan svc.ChangeRequest, status chan<- svc.Status) (bool, uint32) {
	status <- svc.Status{State: svc.StartPending}
	cfg, err := agent.LoadConfig(h.dir)
	if err != nil {
		h.log.Error("load config", "err", err)
		return false, 1
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- (&agent.Agent{Dir: h.dir, Cfg: cfg, Log: h.log}).Run(ctx) }()
	status <- svc.Status{State: svc.Running, Accepts: svc.AcceptStop | svc.AcceptShutdown}
	for {
		select {
		case c := <-req:
			switch c.Cmd {
			case svc.Interrogate:
				status <- c.CurrentStatus
			case svc.Stop, svc.Shutdown:
				status <- svc.Status{State: svc.StopPending}
				cancel()
				<-done
				return false, 0
			}
		case err := <-done:
			cancel()
			if err != nil {
				h.log.Error("agent stopped", "err", err)
				return false, 1
			}
			return false, 0
		}
	}
}
