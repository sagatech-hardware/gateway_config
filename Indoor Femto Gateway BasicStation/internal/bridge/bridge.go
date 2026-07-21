// Package bridge wires the Semtech-UDP packet-forwarder side to the BasicStation
// LNS side and pumps frames between them. Uplink is fully wired; downlink
// (dnmsg → txpk → PULL_RESP) is stubbed pending the next change.
package bridge

import (
	"context"
	"log"
	"sync"

	"github.com/sagatech-hardware/gateway_config/indoor-femto-basicstation/internal/config"
	"github.com/sagatech-hardware/gateway_config/indoor-femto-basicstation/internal/cups"
	"github.com/sagatech-hardware/gateway_config/indoor-femto-basicstation/internal/station"
	"github.com/sagatech-hardware/gateway_config/indoor-femto-basicstation/internal/translate"
	"github.com/sagatech-hardware/gateway_config/indoor-femto-basicstation/internal/udp"
)

// defaultRegion seeds the datr→DR mapping until the LNS router_config supplies
// the authoritative one. This hardware family is AU915.
const defaultRegion = "AU915"

type bridge struct {
	mu     sync.RWMutex
	region string
	srv    *udp.Server
}

// Run connects to the LNS with creds, serves the local packet forwarder, and
// pumps uplinks until ctx is cancelled.
func Run(ctx context.Context, cfg *config.Config, creds *cups.Credentials) error {
	tlsCfg, err := station.TLSFromPEM(creds.TCTrust, creds.TCCert, creds.TCKey)
	if err != nil {
		return err
	}
	routerID, err := cfg.Router()
	if err != nil {
		return err
	}
	st, err := station.Dial(ctx, creds.TCURI, tlsCfg, routerID, cfg.Model)
	if err != nil {
		return err
	}
	defer st.Close()

	b := &bridge{region: defaultRegion, srv: udp.NewServer(cfg.UDPListen)}
	st.OnRouterConfig = func(rc *station.RouterConfig) {
		log.Printf("station: router_config region=%s (%d DRs)", rc.Region, len(rc.DRs))
		b.setRegion(rc.Region)
	}
	st.OnDnmsg = func(dn *station.Dnmsg) {
		// TODO(next): translate.ToDownlink → srv.SendDownlink (RX1/RX2 timing).
		log.Printf("station: downlink received (TX not yet wired): DevEui=%s DR=%d Freq=%d", dn.DevEui, dn.DR, dn.Freq)
	}
	b.srv.OnUplink = func(rx udp.RXPacket) {
		msg, err := translate.ToUplink(rx, b.getRegion())
		if err != nil {
			log.Printf("bridge: drop uplink: %v", err)
			return
		}
		if err := st.Send(msg); err != nil {
			log.Printf("bridge: forward uplink: %v", err)
		}
	}

	errCh := make(chan error, 1)
	go func() { errCh <- b.srv.Serve(ctx) }()
	select {
	case <-ctx.Done():
		return nil
	case err := <-errCh:
		return err
	}
}

func (b *bridge) getRegion() string {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.region
}

func (b *bridge) setRegion(r string) {
	if r == "" {
		return
	}
	b.mu.Lock()
	b.region = r
	b.mu.Unlock()
}
