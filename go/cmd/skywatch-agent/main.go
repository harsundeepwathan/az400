// Command skywatch-agent is the Skywatch host monitoring agent.
//
//	skywatch-agent enroll --server https://ingest.example.com --token swe_...
//	skywatch-agent run            # foreground (systemd unit / Windows service)
//	skywatch-agent status         # show identity and configuration (no secrets)
//	skywatch-agent version
//
// See docs/AGENT.md for installation, upgrade and uninstall procedures.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/harsundeepwathan/az400/go/internal/agent"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: skywatch-agent enroll|run|status|version [flags]")
		os.Exit(2)
	}
	log := slog.New(slog.NewTextHandler(os.Stderr, nil))
	cmd, args := os.Args[1], os.Args[2:]
	fs := flag.NewFlagSet(cmd, flag.ExitOnError)
	dir := fs.String("dir", agent.DefaultDir(), "configuration directory")
	var err error
	switch cmd {
	case "enroll":
		server := fs.String("server", "", "ingest URL, e.g. https://ingest.skywatch.example")
		token := fs.String("token", os.Getenv("SKYWATCH_ENROLLMENT_TOKEN"), "enrollment token (or SKYWATCH_ENROLLMENT_TOKEN)")
		insecure := fs.Bool("allow-insecure-http", false, "allow http:// server URL (local development only)")
		noCloud := fs.Bool("no-cloud-metadata", false, "do not query the cloud instance metadata service")
		_ = fs.Parse(args)
		cfg := &agent.Config{ServerURL: *server, AllowInsecureHTTP: *insecure, DisableCloudProbe: *noCloud}
		if existing, e := agent.LoadConfig(*dir); e == nil && *server == "" {
			cfg = existing
		}
		if err = cfg.Validate(); err == nil {
			if *token == "" {
				err = fmt.Errorf("--token is required")
				break
			}
			var st *agent.State
			st, err = agent.Enroll(context.Background(), *dir, cfg, *token)
			if err == nil {
				fmt.Printf("Enrolled as agent %s (resource %s). Start the service to begin reporting.\n", st.AgentID, st.ResourceID)
			}
		}
	case "run":
		_ = fs.Parse(args)
		err = run(*dir, log)
	case "status":
		_ = fs.Parse(args)
		cfg, e1 := agent.LoadConfig(*dir)
		st, e2 := agent.LoadState(*dir)
		if e1 != nil || e2 != nil {
			err = fmt.Errorf("not enrolled or unreadable config in %s", *dir)
			break
		}
		out, _ := json.MarshalIndent(map[string]any{"server_url": cfg.ServerURL, "agent_id": st.AgentID, "resource_id": st.ResourceID,
			"secret_rotated_at": st.RotatedAt, "version": agent.Version}, "", "  ")
		fmt.Println(string(out))
	case "version":
		fmt.Println(agent.Version)
	default:
		err = fmt.Errorf("unknown command %q", cmd)
	}
	if err != nil {
		log.Error(err.Error())
		os.Exit(1)
	}
}

func runForeground(dir string, log *slog.Logger) error {
	cfg, err := agent.LoadConfig(dir)
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	a := &agent.Agent{Dir: dir, Cfg: cfg, Log: log}
	return a.Run(ctx)
}
