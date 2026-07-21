package translate

import (
	"encoding/base64"
	"encoding/hex"
	"fmt"

	"github.com/sagatech-hardware/gateway_config/indoor-femto-basicstation/internal/station"
	"github.com/sagatech-hardware/gateway_config/indoor-femto-basicstation/internal/udp"
)

// deviceClassC is dC=2 in the LNS protocol (immediate downlink).
const deviceClassC = 2

// defaultTxPowerDBm is the conducted TX power requested in the txpk; the packet
// forwarder snaps it to the nearest tx_gain_lut entry. 915-band gateways top out
// around here.
const defaultTxPowerDBm = 27

// Downlink is the transmit plan for one dnmsg: the primary window plus, for
// class-A frames, an RX2 fallback the bridge sends only if the packet forwarder
// reports it could not transmit at RX1.
type Downlink struct {
	Primary *udp.TXPacket
	RX2     *udp.TXPacket // nil for class C or single-window responses
}

// ToDownlink converts a BasicStation dnmsg into a Semtech transmit plan. Class-A
// windows are scheduled from the uplink reference xtime (RX1 = +RxDelay, RX2 =
// +RxDelay+1s); class C transmits immediately; a single-window form (DR/Freq
// with xtime already the TX time) passes through as-is.
func ToDownlink(dn *station.Dnmsg, region string) (*Downlink, error) {
	pdu, err := hex.DecodeString(dn.Pdu)
	if err != nil {
		return nil, fmt.Errorf("dnmsg pdu hex: %w", err)
	}
	data := base64.StdEncoding.EncodeToString(pdu)
	rctx := uint8(dn.Rctx)

	if dn.DC == deviceClassC {
		tx, err := txpk(region, dn.DR, dn.Freq, 0, true, rctx, len(pdu), data)
		if err != nil {
			return nil, err
		}
		return &Downlink{Primary: tx}, nil
	}

	if dn.RX1Freq > 0 { // class-A two-window form
		base := uint32(dn.Xtime)
		d := rxDelaySeconds(dn.RxDelay)
		rx1, err := txpk(region, dn.RX1DR, dn.RX1Freq, base+uint32(d)*1_000_000, false, rctx, len(pdu), data)
		if err != nil {
			return nil, err
		}
		dl := &Downlink{Primary: rx1}
		if dn.RX2Freq > 0 {
			if rx2, err := txpk(region, dn.RX2DR, dn.RX2Freq, base+uint32(d+1)*1_000_000, false, rctx, len(pdu), data); err == nil {
				dl.RX2 = rx2
			}
		}
		return dl, nil
	}

	// single-window form: xtime is already the TX time
	tx, err := txpk(region, dn.DR, dn.Freq, uint32(dn.Xtime), false, rctx, len(pdu), data)
	if err != nil {
		return nil, err
	}
	return &Downlink{Primary: tx}, nil
}

// txpk assembles a Semtech txpk for one window.
func txpk(region string, dr, freqHz int, tmst uint32, imme bool, rctx uint8, size int, data string) (*udp.TXPacket, error) {
	datr, ok := datrFor(region, dr)
	if !ok {
		return nil, fmt.Errorf("no datr for DR %d in region %s", dr, region)
	}
	if freqHz == 0 {
		return nil, fmt.Errorf("dnmsg has no frequency (DR=%d)", dr)
	}
	return &udp.TXPacket{
		IMME: imme,
		Tmst: tmst,
		Freq: mhzFromHz(freqHz),
		RFCh: rctx,
		Powe: defaultTxPowerDBm,
		Modu: "LORA",
		Datr: datr,
		Codr: "4/5",
		IPol: true, // downlinks use inverted polarity
		Size: size,
		Data: data,
	}, nil
}

// rxDelaySeconds maps the LoRaWAN RxDelay field to seconds (0 means 1s).
func rxDelaySeconds(rxDelay int) int {
	if rxDelay <= 0 {
		return 1
	}
	return rxDelay
}

func mhzFromHz(hz int) float64 { return float64(hz) / 1e6 }
