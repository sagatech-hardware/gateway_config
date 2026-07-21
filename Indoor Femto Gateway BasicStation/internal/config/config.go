// Package config loads the bridge's runtime settings from a `.env` file placed
// next to the binary (the deployment unit is "binary + .env" in one directory).
// Individual settings can be overridden by process environment variables of the
// same name. It is gateway-agnostic: only ROUTER_ID changes between gateways of
// the same hardware type.
package config

import (
	"bufio"
	"encoding/hex"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// DefaultCUPSURI is ThingPark Enterprise SA; override for other LNS providers.
const DefaultCUPSURI = "https://thingparkenterprise.sa.actility.com:443"

// Config is the resolved bridge configuration. ROUTER_ID is the only per-gateway
// value that must change between deployments of the same hardware type.
type Config struct {
	RouterID     string // ROUTER_ID      — gateway identity on the LNS, e.g. 0016C0-80029C4572D3
	RouterFormat string // ROUTER_FORMAT  — raw | hex | id6
	CUPSURI      string // CUPS_URI
	TrustCAPath  string // TRUST_CA_PATH  — PEM to validate TLS; empty = system roots
	LNSURI       string // LNS_URI        — set to skip CUPS and dial this LNS directly
	TCDir        string // TC_DIR         — where tc.* are cached / dropped manually
	UDPListen    string // UDP_LISTEN     — address the local packet forwarder targets
	Model        string // MODEL          — reported to CUPS
}

func defaults() Config {
	return Config{
		RouterFormat: "raw",
		CUPSURI:      DefaultCUPSURI,
		TCDir:        "/mnt/data/pktfwd-station-bridge/tc",
		UDPListen:    "127.0.0.1:1700",
		Model:        "WLRGFM-100",
	}
}

// Load reads the .env file (‑env flag, else PKTFWD_ENV, else <exe dir>/.env,
// else ./.env), applies process-env overrides, and validates.
func Load() (*Config, error) {
	envFlag := flag.String("env", "", "path to .env (default: alongside the binary)")
	flag.Parse()

	cfg := defaults()
	if path := resolveEnvPath(*envFlag); path != "" {
		if err := mergeEnvFile(&cfg, path); err != nil {
			return nil, err
		}
	}
	applyProcessEnv(&cfg)

	if err := cfg.validate(); err != nil {
		return nil, err
	}
	return &cfg, nil
}

func resolveEnvPath(flagVal string) string {
	if flagVal != "" {
		return flagVal
	}
	if v := os.Getenv("PKTFWD_ENV"); v != "" {
		return v
	}
	if exe, err := os.Executable(); err == nil {
		beside := filepath.Join(filepath.Dir(exe), ".env")
		if fileExists(beside) {
			return beside
		}
	}
	if fileExists(".env") {
		return ".env"
	}
	return ""
}

func mergeEnvFile(cfg *Config, path string) error {
	f, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("open %s: %w", path, err)
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		key, val, ok := parseEnvLine(sc.Text())
		if ok {
			setField(cfg, key, val)
		}
	}
	return sc.Err()
}

// parseEnvLine returns KEY, VALUE for a `KEY=VALUE` line, skipping blanks and
// `#` comments. Surrounding quotes on the value are stripped.
func parseEnvLine(line string) (key, val string, ok bool) {
	line = strings.TrimSpace(line)
	if line == "" || strings.HasPrefix(line, "#") {
		return "", "", false
	}
	i := strings.IndexByte(line, '=')
	if i <= 0 {
		return "", "", false
	}
	key = strings.TrimSpace(line[:i])
	val = strings.Trim(strings.TrimSpace(line[i+1:]), `"'`)
	return key, val, true
}

func applyProcessEnv(cfg *Config) {
	for _, key := range []string{"ROUTER_ID", "ROUTER_FORMAT", "CUPS_URI", "TRUST_CA_PATH", "LNS_URI", "TC_DIR", "UDP_LISTEN", "MODEL"} {
		if v, present := os.LookupEnv(key); present {
			setField(cfg, key, v)
		}
	}
}

func setField(cfg *Config, key, val string) {
	switch key {
	case "ROUTER_ID":
		cfg.RouterID = val
	case "ROUTER_FORMAT":
		cfg.RouterFormat = val
	case "CUPS_URI":
		cfg.CUPSURI = val
	case "TRUST_CA_PATH":
		cfg.TrustCAPath = val
	case "LNS_URI":
		cfg.LNSURI = val
	case "TC_DIR":
		cfg.TCDir = val
	case "UDP_LISTEN":
		cfg.UDPListen = val
	case "MODEL":
		cfg.Model = val
	}
}

func (c *Config) validate() error {
	if c.RouterID == "" {
		return fmt.Errorf("ROUTER_ID required (gateway identity, e.g. 0016C0-80029C4572D3)")
	}
	_, err := c.Router()
	return err
}

// Router renders RouterID for the CUPS/LNS "router" field per RouterFormat.
// "raw" strips separators (for vendor ids that are not a bare EUI-64); "hex"
// and "id6" require a 16-hex EUI.
func (c *Config) Router() (string, error) {
	clean := strings.ToLower(strings.NewReplacer(":", "", "-", "").Replace(c.RouterID))
	if _, err := hex.DecodeString(clean); err != nil {
		return "", fmt.Errorf("ROUTER_ID not hex after stripping separators: %w", err)
	}
	switch c.RouterFormat {
	case "raw":
		return clean, nil
	case "", "hex":
		if len(clean) != 16 {
			return "", fmt.Errorf("ROUTER_FORMAT hex needs 16 hex chars, got %d — use raw", len(clean))
		}
		return clean, nil
	case "id6":
		if len(clean) != 16 {
			return "", fmt.Errorf("ROUTER_FORMAT id6 needs 16 hex chars, got %d — use raw", len(clean))
		}
		return fmt.Sprintf("%s:%s:%s:%s", clean[0:4], clean[4:8], clean[8:12], clean[12:16]), nil
	default:
		return "", fmt.Errorf("unknown ROUTER_FORMAT %q (want raw|hex|id6)", c.RouterFormat)
	}
}

func fileExists(p string) bool {
	info, err := os.Stat(p)
	return err == nil && !info.IsDir()
}
