package main

import (
	"github.com/harsundeepwathan/az400/go/internal/providers"
	"github.com/harsundeepwathan/az400/go/internal/providers/alibaba"
	"github.com/harsundeepwathan/az400/go/internal/providers/digitalocean"
)

// extraAdapters returns the non-Azure provider adapters compiled into this build.
func extraAdapters() []providers.Adapter {
	return []providers.Adapter{digitalocean.New(digitalocean.Options{}), alibaba.New(alibaba.Options{})}
}
