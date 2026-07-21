package translate

// Data-rate tables map a packet-forwarder datr string ("SF7BW125") to the LNS
// data-rate index. These are the LoRaWAN RP2 uplink plans; the LNS's
// router_config is authoritative and can override via SetDRTable.
var (
	au915 = map[string]int{
		"SF12BW125": 0, "SF11BW125": 1, "SF10BW125": 2, "SF9BW125": 3,
		"SF8BW125": 4, "SF7BW125": 5, "SF8BW500": 6,
	}
	us915 = map[string]int{
		"SF10BW125": 0, "SF9BW125": 1, "SF8BW125": 2, "SF7BW125": 3, "SF8BW500": 4,
	}
	eu868 = map[string]int{
		"SF12BW125": 0, "SF11BW125": 1, "SF10BW125": 2, "SF9BW125": 3,
		"SF8BW125": 4, "SF7BW125": 5, "SF7BW250": 6,
	}
	regions = map[string]map[string]int{"AU915": au915, "US915": us915, "EU868": eu868}
)

// drFor returns the data-rate index for a datr string in a region. Falls back
// to AU915 for unknown regions (this hardware family is 915-band).
func drFor(region, datr string) (int, bool) {
	table, ok := regions[region]
	if !ok {
		table = au915
	}
	dr, ok := table[datr]
	return dr, ok
}

// Downlink DR → datr. AU915/US915 downlink windows use the BW500 rates DR8-13;
// the uplink DRs are kept for regions (EU868) that reuse them for downlink.
var (
	au915Down = map[int]string{
		8: "SF12BW500", 9: "SF11BW500", 10: "SF10BW500",
		11: "SF9BW500", 12: "SF8BW500", 13: "SF7BW500",
	}
	drDatr = map[string]map[int]string{
		"AU915": au915Down,
		"US915": au915Down,
		"EU868": {0: "SF12BW125", 1: "SF11BW125", 2: "SF10BW125", 3: "SF9BW125", 4: "SF8BW125", 5: "SF7BW125", 6: "SF7BW250"},
	}
)

// datrFor returns the datr string for a downlink data-rate index in a region.
func datrFor(region string, dr int) (string, bool) {
	table, ok := drDatr[region]
	if !ok {
		table = au915Down
	}
	datr, ok := table[dr]
	return datr, ok
}
