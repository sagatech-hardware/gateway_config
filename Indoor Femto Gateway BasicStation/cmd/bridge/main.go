// Command bridge relays a Semtech-UDP packet forwarder to a BasicStation LNS
// (e.g. ThingPark) so gateways that cannot run LoRa Basics Station natively —
// like the Gemtek/Browan Indoor Femto, whose SX1301 sits behind a proprietary
// /dev/semtech0 driver — still reach a CUPS/BasicStation network server.
//
// Uplink (rxpk → updf/jreq) is fully wired; downlink is the next change.
package main

import (
	"context"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/sagatech-hardware/gateway_config/indoor-femto-basicstation/internal/bridge"
	"github.com/sagatech-hardware/gateway_config/indoor-femto-basicstation/internal/config"
	"github.com/sagatech-hardware/gateway_config/indoor-femto-basicstation/internal/cups"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	creds, err := obtainCreds(cfg)
	if err != nil {
		log.Fatalf("credentials: %v", err)
	}
	log.Printf("LNS = %s", creds.TCURI)
	describeCert("tc.crt", creds.TCCert)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	if err := bridge.Run(ctx, cfg, creds); err != nil {
		log.Fatalf("bridge: %v", err)
	}
	log.Printf("shutdown")
}

// obtainCreds prefers cached/manually-dropped tc.* in cfg.TCDir (a portal
// download or a prior bootstrap), else performs a CUPS bootstrap and caches the
// result. CUPS provisioning is typically bound to the gateway's own identity,
// so this must run on the gateway.
func obtainCreds(cfg *config.Config) (*cups.Credentials, error) {
	if c, ok, err := cups.LoadCredentials(cfg.TCDir); err != nil {
		return nil, err
	} else if ok {
		if cfg.LNSURI != "" {
			c.TCURI = cfg.LNSURI
		}
		log.Printf("using tc.* from %s", cfg.TCDir)
		return c, nil
	}
	if cfg.LNSURI != "" {
		return nil, fmt.Errorf("LNS_URI set but no tc.crt/tc.key found in %s", cfg.TCDir)
	}

	router, err := cfg.Router()
	if err != nil {
		return nil, err
	}
	trust, err := readTrust(cfg.TrustCAPath)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	log.Printf("CUPS bootstrap %s router=%s", cfg.CUPSURI, router)
	creds, err := cups.Bootstrap(ctx, cfg.CUPSURI, router, cfg.Model, trust)
	if err != nil {
		return nil, err
	}
	if err := creds.Save(cfg.TCDir); err != nil {
		return nil, fmt.Errorf("cache tc.*: %w", err)
	}
	return creds, nil
}

func readTrust(path string) (string, error) {
	if path == "" {
		return "", nil // system roots
	}
	b, err := os.ReadFile(path)
	return string(b), err
}

func describeCert(label, pemStr string) {
	block, _ := pem.Decode([]byte(pemStr))
	if block == nil {
		return
	}
	c, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return
	}
	log.Printf("%s CN=%q issuer=%q exp=%s", label, c.Subject.CommonName, c.Issuer.CommonName, c.NotAfter.Format("2006-01-02"))
}
