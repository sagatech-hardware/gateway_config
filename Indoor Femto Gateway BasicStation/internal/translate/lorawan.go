// Package translate converts between the Semtech UDP packet-forwarder frames
// (rxpk/txpk) and the LoRa Basics Station LNS messages (updf/jreq/dnmsg). The
// FRMPayload stays encrypted end-to-end: the bridge only parses header fields
// so the LNS can verify the MIC and route the frame.
package translate

import (
	"encoding/binary"
	"fmt"
)

// MAC message types (MHDR >> 5).
const (
	mtypeJoinRequest = 0x00
	mtypeUnconfUp    = 0x02
	mtypeConfUp      = 0x04
)

// Frame is a parsed uplink PHYPayload. For join requests only the join fields
// are set; for data frames only the data fields.
type Frame struct {
	MHDR   byte
	MType  byte
	IsJoin bool
	MIC    uint32

	// data uplink
	DevAddr    uint32
	FCtrl      byte
	FCnt       uint16
	FOpts      []byte
	FPort      int // -1 when absent
	FRMPayload []byte

	// join request
	JoinEUI  uint64
	DevEUI   uint64
	DevNonce uint16
}

// ParsePHY decodes a LoRaWAN PHYPayload (little-endian on the wire).
func ParsePHY(b []byte) (*Frame, error) {
	if len(b) < 5 {
		return nil, fmt.Errorf("PHYPayload too short: %d bytes", len(b))
	}
	f := &Frame{MHDR: b[0], MType: b[0] >> 5, FPort: -1}
	f.MIC = binary.LittleEndian.Uint32(b[len(b)-4:])

	if f.MType == mtypeJoinRequest {
		if len(b) != 23 {
			return nil, fmt.Errorf("join request must be 23 bytes, got %d", len(b))
		}
		f.IsJoin = true
		f.JoinEUI = binary.LittleEndian.Uint64(b[1:9])
		f.DevEUI = binary.LittleEndian.Uint64(b[9:17])
		f.DevNonce = binary.LittleEndian.Uint16(b[17:19])
		return f, nil
	}
	if f.MType != mtypeUnconfUp && f.MType != mtypeConfUp {
		return nil, fmt.Errorf("not an uplink (MType %d)", f.MType)
	}

	// FHDR: DevAddr(4) FCtrl(1) FCnt(2) FOpts(FOptsLen)
	if len(b) < 12 {
		return nil, fmt.Errorf("data frame too short: %d bytes", len(b))
	}
	f.DevAddr = binary.LittleEndian.Uint32(b[1:5])
	f.FCtrl = b[5]
	f.FCnt = binary.LittleEndian.Uint16(b[6:8])
	foptsLen := int(f.FCtrl & 0x0f)
	off := 8
	macEnd := len(b) - 4
	if off+foptsLen > macEnd {
		return nil, fmt.Errorf("FOptsLen %d overruns frame", foptsLen)
	}
	f.FOpts = b[off : off+foptsLen]
	off += foptsLen

	if off < macEnd { // FPort + FRMPayload present
		f.FPort = int(b[off])
		off++
		f.FRMPayload = b[off:macEnd]
	}
	return f, nil
}
