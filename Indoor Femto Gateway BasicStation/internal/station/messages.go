// Package station speaks the LNS-facing half of the LoRa Basics Station
// WebSocket "LNS protocol": it dials the LNS (e.g. ThingPark) with the gateway's
// mTLS credentials, performs the version → router_config handshake, forwards
// uplinks, and receives downlinks. Field names match the wire protocol exactly.
package station

// UpInfo is the radio metadata attached to a BasicStation uplink. Numeric
// identity fields are signed on the wire (see Updf.DevAddr).
type UpInfo struct {
	Rctx    int64   `json:"rctx"`
	Xtime   int64   `json:"xtime"`
	GpsTime int64   `json:"gpstime"`
	RSSI    float64 `json:"rssi"`
	SNR     float64 `json:"snr"`
}

// Updf is a BasicStation uplink data frame. DevAddr and MIC are signed 32-bit on
// the wire; JoinEui/DevEui are signed 64-bit.
type Updf struct {
	MsgType    string `json:"msgtype"`
	MHdr       int    `json:"MHdr"`
	DevAddr    int32  `json:"DevAddr"`
	FCtrl      int    `json:"FCtrl"`
	FCnt       int    `json:"FCnt"`
	FOpts      string `json:"FOpts"`
	FPort      int    `json:"FPort"`
	FRMPayload string `json:"FRMPayload"`
	MIC        int32  `json:"MIC"`
	DR         int    `json:"DR"`
	Freq       int    `json:"Freq"`
	UpInfo     UpInfo `json:"upinfo"`
}

// Jreq is a BasicStation join request.
type Jreq struct {
	MsgType  string `json:"msgtype"`
	MHdr     int    `json:"MHdr"`
	JoinEui  int64  `json:"JoinEui"`
	DevEui   int64  `json:"DevEui"`
	DevNonce int    `json:"DevNonce"`
	MIC      int32  `json:"MIC"`
	DR       int    `json:"DR"`
	Freq     int    `json:"Freq"`
	UpInfo   UpInfo `json:"upinfo"`
}

// RouterConfig is the LNS reply to `version`; DRs is the region data-rate table
// as [SF, BW(kHz), dnOnly] rows, indexed by DR.
type RouterConfig struct {
	MsgType string   `json:"msgtype"`
	Region  string   `json:"region"`
	Hwspec  string   `json:"hwspec"`
	DRs     [][3]int `json:"DRs"`
}

// Dnmsg is a downlink the LNS asks the gateway to transmit. Class-A downlinks
// carry the RX1/RX2 window parameters and a reference xtime (the uplink's), so
// the actual TX time is xtime + RxDelay. Class-C (dC=2) transmit immediately.
// Some LNS variants instead send a single window as DR/Freq with xtime already
// set to the TX time; the translator handles both.
type Dnmsg struct {
	MsgType  string `json:"msgtype"`
	DC       int    `json:"dC"` // device class: 0=A, 1=B, 2=C
	DevEui   string `json:"DevEui"`
	Pdu      string `json:"pdu"` // hex PHYPayload
	Priority int    `json:"priority"`
	RxDelay  int    `json:"RxDelay"`
	RX1DR    int    `json:"RX1DR"`
	RX1Freq  int    `json:"RX1Freq"`
	RX2DR    int    `json:"RX2DR"`
	RX2Freq  int    `json:"RX2Freq"`
	DR       int    `json:"DR"`   // single-window form
	Freq     int    `json:"Freq"` // single-window form
	Xtime    int64  `json:"xtime"`
	Rctx     int64  `json:"rctx"`
	DIID     int64  `json:"diid"`
}
