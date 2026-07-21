// Package bridge wires the Semtech-UDP packet-forwarder side to the BasicStation
// LNS side and pumps frames both ways: uplinks rxpk→updf, downlinks dnmsg→txpk
// with an RX1→RX2 fallback driven by the packet forwarder's TX_ACK.
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

// fallbackRegion seeds the datr→DR mapping when REGION is unset, until the LNS
// router_config supplies the authoritative one.
const fallbackRegion = "US915"

// maxPendingDownlinks caps the RX2-fallback table so missed TX_ACKs cannot leak
// memory; on overflow it is dropped (a downlink stuck without an ack is rare).
const maxPendingDownlinks = 256

type bridge struct {
	mu     sync.RWMutex
	region string
	srv    *udp.Server

	dmu     sync.Mutex
	pending map[[2]byte]*udp.TXPacket // RX2 fallback keyed by RX1 PULL_RESP token
}

// Run connects to the LNS with creds, serves the local packet forwarder, and
// pumps frames until ctx is cancelled.
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

	region := cfg.Region
	if region == "" {
		region = fallbackRegion
	}
	b := &bridge{
		region:  region,
		srv:     udp.NewServer(cfg.UDPListen),
		pending: make(map[[2]byte]*udp.TXPacket),
	}
	st.OnRouterConfig = func(rc *station.RouterConfig) {
		log.Printf("station: router_config region=%s (%d DRs)", rc.Region, len(rc.DRs))
		b.setRegion(rc.Region)
	}
	st.OnDnmsg = b.handleDownlink
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
	b.srv.OnTxAck = b.handleTxAck

	errCh := make(chan error, 1)
	go func() { errCh <- b.srv.Serve(ctx) }()
	select {
	case <-ctx.Done():
		return nil
	case err := <-errCh:
		return err
	}
}

// handleDownlink transmits the primary window and remembers the RX2 fallback so
// handleTxAck can retry if the forwarder can't hit RX1.
func (b *bridge) handleDownlink(dn *station.Dnmsg) {
	dl, err := translate.ToDownlink(dn, b.getRegion())
	if err != nil {
		log.Printf("bridge: drop downlink: %v", err)
		return
	}
	token, err := b.srv.SendTX(dl.Primary)
	if err != nil {
		log.Printf("bridge: send downlink: %v", err)
		return
	}
	if dl.RX2 != nil {
		b.rememberRX2(token, dl.RX2)
	}
	log.Printf("bridge: downlink queued DevEui=%s %.1fMHz %s tmst=%d", dn.DevEui, dl.Primary.Freq, dl.Primary.Datr, dl.Primary.Tmst)
}

// handleTxAck retries at RX2 when the forwarder reports the RX1 transmit failed.
func (b *bridge) handleTxAck(token [2]byte, errStr string) {
	rx2 := b.takeRX2(token)
	if rx2 == nil {
		return
	}
	if errStr == "" {
		return // RX1 accepted; nothing to do
	}
	log.Printf("bridge: RX1 failed (%s) → RX2 %.1fMHz %s tmst=%d", errStr, rx2.Freq, rx2.Datr, rx2.Tmst)
	if _, err := b.srv.SendTX(rx2); err != nil {
		log.Printf("bridge: send RX2: %v", err)
	}
}

func (b *bridge) rememberRX2(token [2]byte, tx *udp.TXPacket) {
	b.dmu.Lock()
	defer b.dmu.Unlock()
	if len(b.pending) >= maxPendingDownlinks {
		b.pending = make(map[[2]byte]*udp.TXPacket)
		log.Printf("bridge: RX2 table overflow, cleared")
	}
	b.pending[token] = tx
}

func (b *bridge) takeRX2(token [2]byte) *udp.TXPacket {
	b.dmu.Lock()
	defer b.dmu.Unlock()
	tx := b.pending[token]
	delete(b.pending, token)
	return tx
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
