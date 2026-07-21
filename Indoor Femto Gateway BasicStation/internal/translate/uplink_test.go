package translate

import (
	"encoding/base64"
	"encoding/hex"
	"testing"

	"github.com/sagatech-hardware/gateway_config/indoor-femto-basicstation/internal/station"
	"github.com/sagatech-hardware/gateway_config/indoor-femto-basicstation/internal/udp"
)

// unconfirmed uplink: MHDR=40 DevAddr=22044704(LE) FCtrl=00 FCnt=1 FPort=1
// FRMPayload=abcd MIC=44332211(LE). DevAddr matches the memory sample device.
const sampleUplinkHex = "4004470422" + "00" + "0100" + "01" + "abcd" + "11223344"

func TestParsePHYDataUplink(t *testing.T) {
	raw, _ := hex.DecodeString(sampleUplinkHex)
	f, err := ParsePHY(raw)
	if err != nil {
		t.Fatalf("ParsePHY: %v", err)
	}
	if f.IsJoin {
		t.Fatal("expected data frame, got join")
	}
	if f.DevAddr != 0x22044704 {
		t.Errorf("DevAddr = %08x, want 22044704", f.DevAddr)
	}
	if f.FCnt != 1 {
		t.Errorf("FCnt = %d, want 1", f.FCnt)
	}
	if f.FPort != 1 {
		t.Errorf("FPort = %d, want 1", f.FPort)
	}
	if got := hex.EncodeToString(f.FRMPayload); got != "abcd" {
		t.Errorf("FRMPayload = %s, want abcd", got)
	}
	if f.MIC != 0x44332211 {
		t.Errorf("MIC = %08x, want 44332211", f.MIC)
	}
}

func TestToUplinkBuildsUpdf(t *testing.T) {
	raw, _ := hex.DecodeString(sampleUplinkHex)
	rx := udp.RXPacket{
		Data: base64.StdEncoding.EncodeToString(raw),
		Datr: "SF7BW125", Freq: 916.6, Tmst: 12345,
		RSSI: -42, LSNR: 9.5, RFCh: 0, Stat: 1, Modu: "LORA",
	}
	msg, err := ToUplink(rx, "AU915")
	if err != nil {
		t.Fatalf("ToUplink: %v", err)
	}
	up, ok := msg.(*station.Updf)
	if !ok {
		t.Fatalf("expected *station.Updf, got %T", msg)
	}
	if up.DR != 5 {
		t.Errorf("DR = %d, want 5 (SF7BW125 AU915)", up.DR)
	}
	if up.Freq != 916600000 {
		t.Errorf("Freq = %d, want 916600000", up.Freq)
	}
	if up.DevAddr != 0x22044704 {
		t.Errorf("DevAddr = %08x, want 22044704", up.DevAddr)
	}
	if up.FRMPayload != "abcd" {
		t.Errorf("FRMPayload = %s, want abcd", up.FRMPayload)
	}
	if up.UpInfo.Xtime != Xtime(12345) {
		t.Errorf("Xtime = %d, want %d", up.UpInfo.Xtime, Xtime(12345))
	}
}

func TestDRForUnknownDatr(t *testing.T) {
	if _, ok := drFor("AU915", "SF7BW125"); !ok {
		t.Error("SF7BW125 should resolve in AU915")
	}
	if _, ok := drFor("AU915", "SF99BW999"); ok {
		t.Error("bogus datr should not resolve")
	}
}
