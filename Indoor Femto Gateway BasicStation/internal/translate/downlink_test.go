package translate

import (
	"testing"

	"github.com/sagatech-hardware/gateway_config/indoor-femto-basicstation/internal/station"
)

func TestToDownlinkClassAWindows(t *testing.T) {
	dn := &station.Dnmsg{
		MsgType: "dnmsg", DC: 0, Pdu: "abcdef",
		RxDelay: 1,
		RX1DR:   8, RX1Freq: 923300000,
		RX2DR: 8, RX2Freq: 923300000,
		Xtime: Xtime(12345), Rctx: 0,
	}
	dl, err := ToDownlink(dn, "AU915")
	if err != nil {
		t.Fatalf("ToDownlink: %v", err)
	}
	rx1 := dl.Primary
	if rx1.IMME {
		t.Error("class A must be scheduled, not immediate")
	}
	if got := hzFromMHz(rx1.Freq); got != 923300000 {
		t.Errorf("RX1 Freq = %d Hz, want 923300000", got)
	}
	if rx1.Datr != "SF12BW500" {
		t.Errorf("RX1 Datr = %s, want SF12BW500 (DR8 AU915 down)", rx1.Datr)
	}
	if rx1.Tmst != 12345+1_000_000 {
		t.Errorf("RX1 Tmst = %d, want %d (xtime + RxDelay)", rx1.Tmst, 12345+1_000_000)
	}
	if !rx1.IPol {
		t.Error("downlink must use inverted polarity")
	}
	if dl.RX2 == nil {
		t.Fatal("RX2 fallback missing")
	}
	if dl.RX2.Tmst != 12345+2_000_000 {
		t.Errorf("RX2 Tmst = %d, want %d (xtime + RxDelay + 1s)", dl.RX2.Tmst, 12345+2_000_000)
	}
}

func TestToDownlinkClassCImmediate(t *testing.T) {
	dn := &station.Dnmsg{MsgType: "dnmsg", DC: 2, Pdu: "ab", DR: 8, Freq: 923300000}
	dl, err := ToDownlink(dn, "AU915")
	if err != nil {
		t.Fatalf("ToDownlink: %v", err)
	}
	if !dl.Primary.IMME {
		t.Error("class C must be immediate")
	}
	if dl.Primary.Tmst != 0 {
		t.Errorf("Tmst = %d, want 0 for immediate", dl.Primary.Tmst)
	}
	if dl.RX2 != nil {
		t.Error("class C should have no RX2 fallback")
	}
}
