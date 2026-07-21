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
