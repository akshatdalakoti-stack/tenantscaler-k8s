package demo

import (
	"errors"
	"path/filepath"
	"strings"
	"testing"

	"tenantscaler/internal/config"
	"tenantscaler/internal/workload"
)

// realConfig is the repository's real-replica config, from this package's
// directory.
var realConfig = filepath.Join("..", "..", "config", "real.yaml")

func TestResolve(t *testing.T) {
	missing := func(config.LlamaSpec) error { return errors.New("llama: no server binary configured") }
	found := func(config.LlamaSpec) error { return nil }
	cpu := func() string { return "Test CPU (4 logical CPUs)" }
	cases := []struct {
		name, mode, path string
		check            func(config.LlamaSpec) error
		wantKind         string
		wantCapacity     int
		wantLabel        string
		wantErr          string
	}{
		{name: "auto without llama falls back to simulated", mode: ModeAuto, check: missing,
			wantKind: config.BackendSimulated, wantCapacity: 10, wantLabel: "SIMULATED engine"},
		{name: "auto with llama uses the given real config", mode: ModeAuto, path: realConfig, check: found,
			wantKind: config.BackendLlama, wantCapacity: 4, wantLabel: "REAL: llama.cpp + "},
		{name: "auto with a real config but no llama is simulated", mode: ModeAuto, path: realConfig, check: missing,
			wantKind: config.BackendSimulated, wantCapacity: 4, wantLabel: "SIMULATED engine"},
		{name: "simulated", mode: ModeSimulated, check: found, wantKind: config.BackendSimulated, wantCapacity: 10,
			wantLabel: "SIMULATED engine"},
		{name: "llama without the files fails", mode: ModeLlama, path: realConfig, check: missing, wantErr: "real replicas unavailable"},
		{name: "unknown mode", mode: "gpu", check: found, wantErr: "backend must be"},
		{name: "missing config file", mode: ModeSimulated, path: "nope.yaml", check: found, wantErr: "nope.yaml"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			cfg, info, err := resolve(c.mode, c.path, c.check, cpu)
			if c.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), c.wantErr) {
					t.Fatalf("err %v, want one containing %q", err, c.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if cfg.Backend.Kind != c.wantKind || info.Kind != c.wantKind || info.Simulated != (c.wantKind == config.BackendSimulated) {
				t.Fatalf("backend %q info %+v, want %q", cfg.Backend.Kind, info, c.wantKind)
			}
			if cfg.Pool.CapacityReplicas != c.wantCapacity || info.Replicas != c.wantCapacity {
				t.Errorf("capacity %d (info %d), want %d", cfg.Pool.CapacityReplicas, info.Replicas, c.wantCapacity)
			}
			if !strings.HasPrefix(info.Label, c.wantLabel) || info.Reason == "" || info.Detail == "" {
				t.Errorf("label %q reason %q detail %q", info.Label, info.Reason, info.Detail)
			}
			if c.wantKind == config.BackendLlama && (info.CPU == "" || !strings.Contains(info.Detail, info.CPU)) {
				t.Errorf("real backend without the CPU: %+v", info)
			}
			if c.path == "" && info.ConfigPath != builtinConfig {
				t.Errorf("config path %q, want %q", info.ConfigPath, builtinConfig)
			}
		})
	}
}

func TestDescribeBackendReal(t *testing.T) {
	cfg, err := config.Load(realConfig)
	if err != nil {
		t.Fatal(err)
	}
	cfg.Backend.Llama.Model = `C:\models\qwen2.5-0.5b-instruct-q4_k_m.gguf`
	info := DescribeBackend(cfg, "")
	want := "REAL: llama.cpp + qwen2.5-0.5b-instruct-q4_k_m on 4 CPU-pinned replicas"
	if info.Label != want || info.Simulated || info.ThreadsPerReplica != 2 || info.SlotsPerReplica != 4 {
		t.Fatalf("info %+v, want label %q", info, want)
	}
	if !strings.HasSuffix(info.Detail, "(2 threads, 4 slots, no GPU).") {
		t.Errorf("detail %q", info.Detail)
	}
}

func TestOptionsValidation(t *testing.T) {
	cases := []struct {
		name    string
		mutate  func(*Options)
		wantErr string
	}{
		{"scenario tenant not configured", func(o *Options) {
			o.Scenario = workload.RealDemoScenario()
			o.Scenario.Tenants[0].Tenant = "Z"
		}, `tenant "Z" is not in the config`},
		{"GPU offload with llama", func(o *Options) {
			o.Config.Backend.Kind = config.BackendLlama
			o.Config.Backend.Llama.GPULayers = 99
		}, "CPU only"},
		{"negative cooldown", func(o *Options) { o.Cooldown = -1 }, "must be >= 0"},
		{"invalid scenario", func(o *Options) { o.Scenario.Duration = 0 }, "duration"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			opt := testOptions(t)
			c.mutate(&opt)
			if _, err := New(opt); err == nil || !strings.Contains(err.Error(), c.wantErr) {
				t.Fatalf("err %v, want one containing %q", err, c.wantErr)
			}
		})
	}
	opt := testOptions(t)
	opt.InitialReplicas = 99
	srv, err := New(opt)
	if err != nil {
		t.Fatal(err)
	}
	if srv.opt.InitialReplicas != 3 || srv.opt.Window != DefaultWindow || srv.opt.ResultsDir == "" {
		t.Errorf("normalized options %+v", srv.opt)
	}
}

// A dashboard observing a cluster sends no traffic of its own, so a scenario
// tenant the config does not list is not a fault: the cluster's tenants are
// lower case because a TenantScaler's name is its fairness id, while the
// scenario names them A, B and C. Requiring a match here crash-looped the
// in-cluster dashboard (deploy/k8s/50-dashboard.yaml), which mounts the
// cluster's own config.
func TestObservingAcceptsScenarioTenantsOutsideTheConfig(t *testing.T) {
	opt := testOptions(t)
	opt.Backend = ObservedBackend(opt.Config, "test", true)
	opt.Scenario = workload.RealDemoScenario()
	for i := range opt.Scenario.Tenants {
		opt.Scenario.Tenants[i].Tenant = strings.ToUpper(opt.Scenario.Tenants[i].Tenant)
	}
	lower := opt.Config.Tenants[0].Name
	opt.Config.Tenants[0].Name = strings.ToLower(lower)
	if _, err := New(opt); err != nil {
		t.Fatalf("observing a cluster: %v", err)
	}

	// The check still applies when this dashboard is the one sending the
	// requests, which is the case it exists for.
	opt.Backend = ObservedBackend(opt.Config, "test", true)
	opt.Backend.Kind = config.BackendSimulated
	if _, err := New(opt); err == nil || !strings.Contains(err.Error(), "is not in the config") {
		t.Fatalf("running its own traffic: err %v, want one about a tenant not in the config", err)
	}
}
