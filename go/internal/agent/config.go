// Package agent implements the Skywatch monitoring agent.
//
// Design constraints (see docs/AGENT.md):
//   - Outbound HTTPS only; the agent opens no listening ports.
//   - No remote command execution: the server can change collection intervals and the
//     list of watched services, nothing else.
//   - Collects host metrics, filesystem usage, OS identity and service states only. It
//     never reads process command lines, environment variables, files or credentials.
package agent

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"time"
)

// Version is set at build time.
var Version = "1.0.0-dev"

// Config is the on-disk agent configuration (non-secret).
type Config struct {
	ServerURL         string   `json:"server_url"`
	AllowInsecureHTTP bool     `json:"allow_insecure_http,omitempty"` // development only
	CAFile            string   `json:"ca_file,omitempty"`
	DisableCloudProbe bool     `json:"disable_cloud_metadata,omitempty"`
	ExcludeMounts     []string `json:"exclude_mounts,omitempty"`
	ExtraServices     []string `json:"watch_services,omitempty"` // in addition to server-provided list
	QueueSize         int      `json:"queue_size,omitempty"`
}

// State holds the agent identity. Written with 0600 permissions.
type State struct {
	AgentID     string    `json:"agent_id"`
	AgentSecret string    `json:"agent_secret"`
	ResourceID  string    `json:"resource_id"`
	RotatedAt   time.Time `json:"rotated_at"`
	Seq         int64     `json:"seq"`
}

// DefaultDir returns the platform configuration directory.
func DefaultDir() string {
	if runtime.GOOS == "windows" {
		pd := os.Getenv("ProgramData")
		if pd == "" {
			pd = `C:\ProgramData`
		}
		return filepath.Join(pd, "Skywatch")
	}
	return "/etc/skywatch-agent"
}

// LoadConfig reads config.json from dir.
func LoadConfig(dir string) (*Config, error) {
	b, err := os.ReadFile(filepath.Join(dir, "config.json"))
	if err != nil {
		return nil, err
	}
	var c Config
	if err := json.Unmarshal(b, &c); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}
	return &c, c.Validate()
}

// Validate checks the configuration.
func (c *Config) Validate() error {
	u, err := url.Parse(c.ServerURL)
	if err != nil || u.Host == "" {
		return errors.New("server_url must be an absolute URL")
	}
	if u.Scheme != "https" && !(u.Scheme == "http" && c.AllowInsecureHTTP) {
		return errors.New("server_url must use https (set allow_insecure_http only for local development)")
	}
	if c.QueueSize <= 0 {
		c.QueueSize = 720 // 12 hours of one-minute batches
	}
	return nil
}

// SaveConfig writes config.json.
func SaveConfig(dir string, c *Config) error {
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return err
	}
	b, _ := json.MarshalIndent(c, "", "  ")
	return writeFileAtomic(filepath.Join(dir, "config.json"), b, 0o640)
}

// LoadState reads state.json.
func LoadState(dir string) (*State, error) {
	b, err := os.ReadFile(filepath.Join(dir, "state.json"))
	if err != nil {
		return nil, err
	}
	var s State
	return &s, json.Unmarshal(b, &s)
}

// SaveState atomically writes state.json readable only by the agent's user.
func SaveState(dir string, s *State) error {
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return err
	}
	b, _ := json.MarshalIndent(s, "", "  ")
	return writeFileAtomic(filepath.Join(dir, "state.json"), b, 0o600)
}

func writeFileAtomic(path string, b []byte, mode os.FileMode) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, mode); err != nil {
		return err
	}
	if err := os.Chmod(tmp, mode); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
