package main

import "github.com/harsundeepwathan/az400/go/internal/providers"

// extraAdapters returns the non-Azure provider adapters compiled into this build.
func extraAdapters() []providers.Adapter { return nil }
