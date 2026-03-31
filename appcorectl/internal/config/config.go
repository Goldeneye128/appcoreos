package config

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

const (
	defaultConfigRelPath = ".config/appcorectl/config.yaml"
	defaultAuditRelPath  = ".local/state/appcorectl/audit.log"
	defaultPKIRelRoot    = ".local/share/appcorectl/pki"
)

// TargetProfile stores per-target connection and auth settings.
type TargetProfile struct {
	URL      string `yaml:"url" json:"url"`
	CAPath   string `yaml:"ca" json:"ca"`
	CertPath string `yaml:"cert" json:"cert"`
	KeyPath  string `yaml:"key" json:"key"`
	APIKey   string `yaml:"api_key" json:"api_key"`
	Insecure bool   `yaml:"insecure" json:"insecure"`
}

// Config is the persisted CLI configuration.
type Config struct {
	CurrentTarget string                   `yaml:"current_target" json:"current_target"`
	Output        string                   `yaml:"output" json:"output"`
	Targets       map[string]TargetProfile `yaml:"targets" json:"targets"`
}

func DefaultConfigPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve home directory: %w", err)
	}
	return filepath.Join(home, defaultConfigRelPath), nil
}

func DefaultAuditLogPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve home directory: %w", err)
	}
	return filepath.Join(home, defaultAuditRelPath), nil
}

func DefaultPKIRootDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve home directory: %w", err)
	}
	return filepath.Join(home, defaultPKIRelRoot), nil
}

func ResolveConfigPath(flagPath string) (string, error) {
	if strings.TrimSpace(flagPath) != "" {
		return ExpandPath(flagPath)
	}
	if env := strings.TrimSpace(os.Getenv("APPCORECTL_CONFIG")); env != "" {
		return ExpandPath(env)
	}
	return DefaultConfigPath()
}

func ExpandPath(path string) (string, error) {
	path = strings.TrimSpace(path)
	if path == "" {
		return "", errors.New("path is empty")
	}
	if path == "~" || strings.HasPrefix(path, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("resolve home directory: %w", err)
		}
		if path == "~" {
			return home, nil
		}
		path = filepath.Join(home, strings.TrimPrefix(path, "~/"))
	}
	return filepath.Abs(path)
}

func New() *Config {
	return &Config{
		Output:  "table",
		Targets: make(map[string]TargetProfile),
	}
}

func (c *Config) Normalize() {
	if c.Output == "" {
		c.Output = "table"
	}
	if c.Targets == nil {
		c.Targets = make(map[string]TargetProfile)
	}
}

func Load(path string) (*Config, error) {
	cfg := New()
	bytes, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return cfg, nil
		}
		return nil, fmt.Errorf("read config file: %w", err)
	}
	if len(bytes) == 0 {
		return cfg, nil
	}
	if err := yaml.Unmarshal(bytes, cfg); err != nil {
		return nil, fmt.Errorf("parse config file: %w", err)
	}
	cfg.Normalize()
	return cfg, nil
}

func Save(path string, cfg *Config) error {
	cfg.Normalize()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("create config directory: %w", err)
	}
	bytes, err := yaml.Marshal(cfg)
	if err != nil {
		return fmt.Errorf("marshal config: %w", err)
	}
	tmpPath := path + ".tmp"
	if err := os.WriteFile(tmpPath, bytes, 0o600); err != nil {
		return fmt.Errorf("write temp config: %w", err)
	}
	if err := os.Rename(tmpPath, path); err != nil {
		return fmt.Errorf("replace config file: %w", err)
	}
	return nil
}

func (c *Config) ActiveTarget(name string) (TargetProfile, error) {
	profile, ok := c.Targets[name]
	if !ok {
		return TargetProfile{}, fmt.Errorf("target %q not found", name)
	}
	return profile, nil
}

func EnvString(key string) string {
	return strings.TrimSpace(os.Getenv(key))
}

func EnvBool(key string) (bool, bool, error) {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return false, false, nil
	}
	val, err := strconv.ParseBool(raw)
	if err != nil {
		return false, true, fmt.Errorf("parse %s as bool: %w", key, err)
	}
	return val, true, nil
}

func MergeTarget(base TargetProfile, flag TargetProfile) (TargetProfile, error) {
	merged := base
	if env := EnvString("APPCORECTL_URL"); env != "" {
		merged.URL = env
	}
	if env := EnvString("APPCORECTL_CA"); env != "" {
		merged.CAPath = env
	}
	if env := EnvString("APPCORECTL_CERT"); env != "" {
		merged.CertPath = env
	}
	if env := EnvString("APPCORECTL_KEY"); env != "" {
		merged.KeyPath = env
	}
	if env := EnvString("APPCORECTL_API_KEY"); env != "" {
		merged.APIKey = env
	}
	if insecure, ok, err := EnvBool("APPCORECTL_INSECURE"); err != nil {
		return TargetProfile{}, err
	} else if ok {
		merged.Insecure = insecure
	}
	if flag.URL != "" {
		merged.URL = flag.URL
	}
	if flag.CAPath != "" {
		merged.CAPath = flag.CAPath
	}
	if flag.CertPath != "" {
		merged.CertPath = flag.CertPath
	}
	if flag.KeyPath != "" {
		merged.KeyPath = flag.KeyPath
	}
	if flag.APIKey != "" {
		merged.APIKey = flag.APIKey
	}
	if flag.Insecure {
		merged.Insecure = true
	}

	if merged.CertPath == "" && merged.KeyPath != "" {
		return TargetProfile{}, errors.New("--key set without --cert")
	}
	if merged.KeyPath == "" && merged.CertPath != "" {
		return TargetProfile{}, errors.New("--cert set without --key")
	}
	return merged, nil
}

func ResolveOutput(flagOutput, configOutput string) string {
	if strings.TrimSpace(flagOutput) != "" {
		return strings.ToLower(strings.TrimSpace(flagOutput))
	}
	if env := strings.ToLower(EnvString("APPCORECTL_OUTPUT")); env != "" {
		return env
	}
	if configOutput == "" {
		return "table"
	}
	return strings.ToLower(configOutput)
}
