package main

import "testing"

// A client started with --vin B must not adopt an operational certificate that
// was issued to A. Three clients started in one directory did exactly that on
// 2026-09-24: VEHICLE006 and VEHICLE007 published under VEHICLE005's identity,
// because the stored files carry no VIN in their names and the reuse check only
// looked at the expiry date.
func TestCertificateBelongsToVIN(t *testing.T) {
	cases := []struct {
		cn, vin string
		want    bool
	}{
		{"VIN:VEHICLE005 DEVICE:VEHICLE005", "VEHICLE005", true},
		{"VIN:VEHICLE005 DEVICE:VEHICLE005", "VEHICLE006", false}, // the real case
		{"VIN:VEHICLE005 DEVICE:car", "VEHICLE005", true},         // other DEVICE conventions
		{"VIN:VEHICLE0050 DEVICE:x", "VEHICLE005", false},         // no prefix matching
		{"", "VEHICLE005", false},
		{"CN=nonsense", "VEHICLE005", false},
	}
	for _, c := range cases {
		if got := certificateBelongsToVIN(c.cn, c.vin); got != c.want {
			t.Errorf("cn %q against vin %q: got %v, want %v", c.cn, c.vin, got, c.want)
		}
	}
}
