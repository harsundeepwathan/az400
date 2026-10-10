package telemetry

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"
)

// TestSchemaMatchesTypes is the API contract test between the published JSON Schema
// (docs/api/agent-v1.schema.json) and the Go types the agent and ingest share: every
// field the types serialize must be declared by the schema, and every schema property
// must exist in the types.
func TestSchemaMatchesTypes(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "docs", "api", "agent-v1.schema.json"))
	if err != nil {
		t.Fatal(err)
	}
	var schema map[string]any
	if err := json.Unmarshal(raw, &schema); err != nil {
		t.Fatal(err)
	}
	check := func(name string, typ reflect.Type, node map[string]any) {
		props, _ := node["properties"].(map[string]any)
		var schemaKeys, typeKeys []string
		for k := range props {
			schemaKeys = append(schemaKeys, k)
		}
		for i := 0; i < typ.NumField(); i++ {
			tag := strings.Split(typ.Field(i).Tag.Get("json"), ",")[0]
			if tag != "" && tag != "-" {
				typeKeys = append(typeKeys, tag)
			}
		}
		sort.Strings(schemaKeys)
		sort.Strings(typeKeys)
		if !reflect.DeepEqual(schemaKeys, typeKeys) {
			t.Errorf("%s: schema properties %v != type fields %v", name, schemaKeys, typeKeys)
		}
	}
	props := schema["properties"].(map[string]any)
	item := func(k string) map[string]any { return props[k].(map[string]any)["items"].(map[string]any) }
	check("Batch", reflect.TypeOf(Batch{}), schema)
	check("HostInfo", reflect.TypeOf(HostInfo{}), props["host"].(map[string]any))
	check("AgentHealth", reflect.TypeOf(AgentHealth{}), props["agent"].(map[string]any))
	check("Sample", reflect.TypeOf(Sample{}), item("metrics"))
	check("Service", reflect.TypeOf(Service{}), item("services"))
	check("Event", reflect.TypeOf(Event{}), item("events"))
	check("PartialInfo", reflect.TypeOf(PartialInfo{}), item("partial"))
}

func TestValidate(t *testing.T) {
	ok := Batch{Version: "1", BatchID: "0b8f0b1e-8a7c-4e3c-9d55-7d1b2c3a4f50", Metrics: []Sample{{Metric: "cpu.utilization", TS: time.Now(), Value: 1}},
		Services: []Service{{Platform: "systemd", Name: "nginx.service", State: "running"}}}
	if err := ok.Validate(); err != nil {
		t.Fatal(err)
	}
	cases := map[string]func(b *Batch){
		"version":       func(b *Batch) { b.Version = "2" },
		"batch id":      func(b *Batch) { b.BatchID = "x" },
		"metric name":   func(b *Batch) { b.Metrics[0].Metric = "CPU; DROP" },
		"zero ts":       func(b *Batch) { b.Metrics[0].TS = time.Time{} },
		"service state": func(b *Batch) { b.Services[0].State = "exploded" },
		"platform":      func(b *Batch) { b.Services[0].Platform = "launchd" },
	}
	for name, mut := range cases {
		b := ok
		b.Metrics = append([]Sample{}, ok.Metrics...)
		b.Services = append([]Service{}, ok.Services...)
		mut(&b)
		if b.Validate() == nil {
			t.Errorf("%s: invalid batch accepted", name)
		}
	}
}
