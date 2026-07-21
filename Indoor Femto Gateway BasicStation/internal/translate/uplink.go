package translate

import (
	"encoding/base64"
	"encoding/hex"
	"fmt"

	"github.com/sagatech-hardware/gateway_config/indoor-femto-basicstation/internal/station"
	"github.com/sagatech-hardware/gateway_config/indoor-femto-basicstation/internal/udp"
)

// xtimeSession marks the high bits of the 64-bit BasicStation xtime; the low
// 32 bits carry the concentrator tmst so the LNS can schedule RX windows and
// the downlink path can recover tmst (see ToDownlink).
const xtimeSession int64 = 1 << 48

// ToUplink converts a received rxpk into a BasicStation uplink message — a
// *station.Jreq for join requests, otherwise a *station.Updf. region selects
// the datr→DR mapping.
func ToUplink(rx udp.RXPacket, region string) (any, error) {
	raw, err := base64.StdEncoding.DecodeString(rx.Data)
	if err != nil {
		return nil, fmt.Errorf("rxpk data base64: %w", err)
	}
	f, err := ParsePHY(raw)
	if err != nil {
		return nil, err
	}
	dr, ok := drFor(region, rx.Datr)
	if !ok {
		return nil, fmt.Errorf("no DR for datr %q in region %s", rx.Datr, region)
	}
	info := station.UpInfo{
		Rctx:  int64(rx.RFCh),
		Xtime: Xtime(rx.Tmst),
		RSSI:  rx.RSSI,
		SNR:   rx.LSNR,
	}
	freq := hzFromMHz(rx.Freq)

	if f.IsJoin {
		return &station.Jreq{
			MsgType: "jreq", MHdr: int(f.MHDR),
			JoinEui: int64(f.JoinEUI), DevEui: int64(f.DevEUI),
			DevNonce: int(f.DevNonce), MIC: int32(f.MIC),
			DR: dr, Freq: freq, UpInfo: info,
		}, nil
	}
	return &station.Updf{
		MsgType: "updf", MHdr: int(f.MHDR),
		DevAddr: int32(f.DevAddr), FCtrl: int(f.FCtrl), FCnt: int(f.FCnt),
		FOpts: hex.EncodeToString(f.FOpts), FPort: f.FPort,
		FRMPayload: hex.EncodeToString(f.FRMPayload), MIC: int32(f.MIC),
		DR: dr, Freq: freq, UpInfo: info,
	}, nil
}

// Xtime packs a concentrator tmst into a BasicStation xtime.
func Xtime(tmst uint32) int64 { return xtimeSession | int64(tmst) }

func hzFromMHz(mhz float64) int { return int(mhz*1e6 + 0.5) }
