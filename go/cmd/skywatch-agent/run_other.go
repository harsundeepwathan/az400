//go:build !windows

package main

import "log/slog"

func run(dir string, log *slog.Logger) error { return runForeground(dir, log) }
