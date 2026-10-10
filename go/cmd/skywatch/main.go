// Command skywatch runs the Skywatch monitoring backend. One binary, several roles:
//
//	skywatch migrate                      apply database migrations
//	skywatch seed-demo                    create the demo + isolation-test organizations
//	skywatch serve [--roles=a,b,...]      run roles: collector, evaluator, ingest,
//	                                      notifier, probe, maintenance, demo
//
// Small installs run every role in one process; larger ones scale roles independently.
// Configuration is read from the environment (see deploy/.env.example).
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus/promhttp"
	"golang.org/x/sync/errgroup"

	"github.com/harsundeepwathan/az400/go/internal/collector"
	"github.com/harsundeepwathan/az400/go/internal/db"
	"github.com/harsundeepwathan/az400/go/internal/evaluator"
	"github.com/harsundeepwathan/az400/go/internal/ingest"
	"github.com/harsundeepwathan/az400/go/internal/maintenance"
	"github.com/harsundeepwathan/az400/go/internal/netguard"
	"github.com/harsundeepwathan/az400/go/internal/notify"
	"github.com/harsundeepwathan/az400/go/internal/probe"
	"github.com/harsundeepwathan/az400/go/internal/providers"
	"github.com/harsundeepwathan/az400/go/internal/providers/azure"
	"github.com/harsundeepwathan/az400/go/internal/secrets"
	"github.com/harsundeepwathan/az400/go/internal/seed"
	"github.com/harsundeepwathan/az400/go/internal/selfmon"
)

var version = "dev"

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: skywatch migrate|seed-demo|serve|version")
		os.Exit(2)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	var err error
	switch os.Args[1] {
	case "migrate":
		err = migrate(ctx, log)
	case "seed-demo":
		err = seedDemo(ctx, log)
	case "serve":
		err = serve(ctx, log, os.Args[2:])
	case "version":
		fmt.Println(version)
	default:
		err = fmt.Errorf("unknown command %q", os.Args[1])
	}
	if err != nil {
		log.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func migrate(ctx context.Context, log *slog.Logger) error {
	dsn := env("SKYWATCH_MIGRATE_DATABASE_URL", os.Getenv("SKYWATCH_DATABASE_URL"))
	if dsn == "" {
		return errors.New("SKYWATCH_MIGRATE_DATABASE_URL is required")
	}
	applied, err := db.Migrate(ctx, dsn, env("SKYWATCH_MIGRATIONS_DIR", "db/migrations"))
	log.Info("migrations applied", "versions", applied)
	return err
}

func seedDemo(ctx context.Context, log *slog.Logger) error {
	pool, err := db.Connect(ctx, os.Getenv("SKYWATCH_DATABASE_URL"))
	if err != nil {
		return err
	}
	defer pool.Close()
	pw := env("SKYWATCH_DEMO_PASSWORD", "skywatch-demo")
	res, err := seed.Demo(ctx, pool, pw)
	if err != nil {
		return err
	}
	log.Info("demo environment seeded (local development credentials)", "users", res.Users, "password_env", "SKYWATCH_DEMO_PASSWORD")
	return nil
}

func serve(ctx context.Context, log *slog.Logger, args []string) error {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	rolesFlag := fs.String("roles", env("SKYWATCH_ROLES", "collector,evaluator,ingest,notifier,probe,maintenance"), "comma-separated roles")
	if err := fs.Parse(args); err != nil {
		return err
	}
	roles := map[string]bool{}
	var roleList []string
	for _, r := range strings.Split(*rolesFlag, ",") {
		if r = strings.TrimSpace(r); r != "" {
			roles[r] = true
			roleList = append(roleList, r)
		}
	}
	pool, err := db.Connect(ctx, os.Getenv("SKYWATCH_DATABASE_URL"))
	if err != nil {
		return fmt.Errorf("database: %w", err)
	}
	defer pool.Close()

	var keys secrets.KeyProvider
	if roles["collector"] || roles["notifier"] {
		kr, err := secrets.LocalKeyringFromEnv()
		if err != nil {
			return fmt.Errorf("key provider: %w", err)
		}
		keys = kr
	}
	host, _ := os.Hostname()
	suffix := make([]byte, 3)
	_, _ = rand.Read(suffix)
	instanceID := env("SKYWATCH_INSTANCE_ID", host+"-"+hex.EncodeToString(suffix))
	log = log.With("instance", instanceID)

	g, gctx := errgroup.WithContext(ctx)
	g.Go(func() error { selfmon.Heartbeat(gctx, pool, instanceID, version, roleList, log); return nil })

	// Metrics / health endpoint for the platform itself.
	metricsSrv := &http.Server{Addr: env("SKYWATCH_METRICS_ADDR", ":9090"), ReadHeaderTimeout: 5 * time.Second}
	mmux := http.NewServeMux()
	mmux.Handle("/metrics", promhttp.Handler())
	mmux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte("ok")) })
	metricsSrv.Handler = mmux
	g.Go(func() error { return listen(gctx, metricsSrv, "", "") })

	if roles["collector"] {
		adapters := []providers.Adapter{azure.New(azure.Options{})}
		adapters = append(adapters, extraAdapters()...)
		s := collector.New(pool, keys, adapters, collector.Config{InstanceID: instanceID}, log.With("role", "collector"))
		g.Go(func() error { return s.Run(gctx) })
	}
	if roles["evaluator"] {
		e := evaluator.New(pool, evaluator.Config{}, log.With("role", "evaluator"))
		g.Go(func() error { return e.Run(gctx) })
	}
	if roles["ingest"] {
		srv := ingest.New(pool, log.With("role", "ingest"))
		srv.TrustProxyHeaders = os.Getenv("SKYWATCH_TRUST_PROXY") == "true"
		hs := &http.Server{Addr: env("SKYWATCH_INGEST_ADDR", ":8443"), Handler: srv.Handler(),
			ReadHeaderTimeout: 10 * time.Second, ReadTimeout: 30 * time.Second, WriteTimeout: 30 * time.Second}
		cert, key := os.Getenv("SKYWATCH_TLS_CERT"), os.Getenv("SKYWATCH_TLS_KEY")
		if cert == "" {
			log.Warn("ingest listening without TLS: terminate TLS at a reverse proxy; agents refuse plain HTTP unless explicitly allowed")
		}
		g.Go(func() error { return listen(gctx, hs, cert, key) })
	}
	if roles["notifier"] {
		n := notify.New(pool, keys, notify.Config{
			PublicURL: os.Getenv("SKYWATCH_PUBLIC_URL"), SMTPAddr: os.Getenv("SKYWATCH_SMTP_ADDR"), SMTPFrom: env("SKYWATCH_SMTP_FROM", "skywatch@localhost"),
			SMTPUser: os.Getenv("SKYWATCH_SMTP_USER"), SMTPPass: os.Getenv("SKYWATCH_SMTP_PASSWORD"),
			AllowPrivateTargets: os.Getenv("SKYWATCH_NOTIFY_ALLOW_PRIVATE") == "true",
		}, log.With("role", "notifier"))
		g.Go(func() error { return n.Run(gctx) })
	}
	if roles["probe"] {
		scope := env("SKYWATCH_PROBE_SCOPE", "public")
		w := &probe.Worker{Pool: pool, Location: env("SKYWATCH_PROBE_LOCATION", "default"), Scope: scope,
			OrgID: os.Getenv("SKYWATCH_PROBE_ORG_ID"), Log: log.With("role", "probe"),
			Runner: &probe.Runner{Policy: netguard.Policy{AllowPrivate: scope == "private"}}}
		if scope == "private" && w.OrgID == "" {
			return errors.New("private probes must be bound to one organization (SKYWATCH_PROBE_ORG_ID)")
		}
		g.Go(func() error { return w.Run(gctx) })
	}
	if roles["maintenance"] {
		j := &maintenance.Job{Pool: pool, Retention: maintenance.DefaultRetention, Log: log.With("role", "maintenance")}
		g.Go(func() error { return j.Run(gctx, 10*time.Minute) })
	}
	if roles["demo"] {
		g.Go(func() error {
			t := time.NewTicker(time.Minute)
			defer t.Stop()
			for {
				if err := seed.SimulateServices(gctx, pool); err != nil && gctx.Err() == nil {
					log.Warn("demo service simulation", "err", err)
				}
				select {
				case <-gctx.Done():
					return nil
				case <-t.C:
				}
			}
		})
	}
	log.Info("skywatch started", "version", version, "roles", roleList)
	return g.Wait()
}

func listen(ctx context.Context, s *http.Server, cert, key string) error {
	errc := make(chan error, 1)
	go func() {
		var err error
		if cert != "" {
			err = s.ListenAndServeTLS(cert, key)
		} else {
			err = s.ListenAndServe()
		}
		if errors.Is(err, http.ErrServerClosed) {
			err = nil
		}
		errc <- err
	}()
	select {
	case <-ctx.Done():
		sctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return s.Shutdown(sctx)
	case err := <-errc:
		return err
	}
}
