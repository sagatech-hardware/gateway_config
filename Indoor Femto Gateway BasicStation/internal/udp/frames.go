// Package udp implements the LNS-facing half of the Semtech UDP packet-forwarder
// protocol: it listens for the gateway's native lora_pkt_fwd, ACKs its uplinks,
// and can push downlinks back. Frame layout per Semtech "PROTOCOL.TXT".
package udp

import "encoding/json"

// Protocol version and packet identifiers (Semtech UDP).
const (
	ProtoVersion byte = 0x02
	PushData     byte = 0x00
	PushAck      byte = 0x01
	PullData     byte = 0x02
	PullResp     byte = 0x03
	PullAck      byte = 0x04
	TxAck        byte = 0x05
)

// RXPacket is one received LoRa frame ("rxpk") from the packet forwarder. Only
// the fields the bridge needs to build a BasicStation uplink are modelled.
type RXPacket struct {
	Tmst uint32  `json:"tmst"` // concentrator timestamp (µs)
	Freq float64 `json:"freq"` // MHz
	Chan uint8   `json:"chan"`
	RFCh uint8   `json:"rfch"`
	Stat int8    `json:"stat"` // CRC: 1 ok, -1 fail, 0 none
	Modu string  `json:"modu"` // "LORA" | "FSK"
	Datr string  `json:"datr"` // e.g. "SF7BW125"
	Codr string  `json:"codr"` // e.g. "4/5"
	RSSI float64 `json:"rssi"`
	LSNR float64 `json:"lsnr"`
	Data string  `json:"data"` // base64 PHYPayload
}

// pushPayload is the JSON body of a PUSH_DATA packet.
type pushPayload struct {
	RXPK []RXPacket `json:"rxpk"`
}

// TXPacket is a downlink ("txpk") the bridge asks the packet forwarder to emit.
type TXPacket struct {
	IMME bool    `json:"imme"`
	Tmst uint32  `json:"tmst"`
	Freq float64 `json:"freq"`
	RFCh uint8   `json:"rfch"`
	Powe int     `json:"powe"`
	Modu string  `json:"modu"`
	Datr string  `json:"datr"`
	Codr string  `json:"codr"`
	IPol bool    `json:"ipol"`
	Size int     `json:"size"`
	Data string  `json:"data"` // base64 PHYPayload
}

// decodePushData extracts the rxpk list from a PUSH_DATA packet. Header is
// 12 bytes: version(1) token(2) id(1) gatewayEUI(8).
func decodePushData(pkt []byte) ([]RXPacket, error) {
	if len(pkt) <= 12 {
		return nil, nil // header only (some forwarders send empty)
	}
	var body pushPayload
	if err := json.Unmarshal(pkt[12:], &body); err != nil {
		return nil, err
	}
	return body.RXPK, nil
}

// encodePullResp wraps a txpk in a PULL_RESP packet: version(1) token(2) id(1)
// then the JSON body.
func encodePullResp(token [2]byte, tx *TXPacket) ([]byte, error) {
	body, err := json.Marshal(map[string]*TXPacket{"txpk": tx})
	if err != nil {
		return nil, err
	}
	pkt := []byte{ProtoVersion, token[0], token[1], PullResp}
	return append(pkt, body...), nil
}

// ackFor builds the 4-byte acknowledgement (PUSH_ACK/PULL_ACK) echoing the
// received token.
func ackFor(pkt []byte, ackID byte) []byte {
	var t0, t1 byte
	if len(pkt) >= 3 {
		t0, t1 = pkt[1], pkt[2]
	}
	return []byte{ProtoVersion, t0, t1, ackID}
}

// decodeTxAck extracts the echoed token and error from a TX_ACK. Header is
// version(1) token(2) id(1) gatewayEUI(8) then optional JSON
// {"txpk_ack":{"error":"NONE"}}. An empty or "NONE" error means the downlink
// was accepted for transmission.
func decodeTxAck(pkt []byte) (token [2]byte, errStr string) {
	if len(pkt) >= 3 {
		token[0], token[1] = pkt[1], pkt[2]
	}
	if len(pkt) <= 12 {
		return token, ""
	}
	var body struct {
		Ack struct {
			Error string `json:"error"`
		} `json:"txpk_ack"`
	}
	if json.Unmarshal(pkt[12:], &body) != nil || body.Ack.Error == "NONE" {
		return token, ""
	}
	return token, body.Ack.Error
}
