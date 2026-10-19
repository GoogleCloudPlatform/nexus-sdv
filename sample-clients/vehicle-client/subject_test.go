package main

import (
	"testing"
)

// The subject names the format and the vehicle: the Nexus message goes on
// telemetry.<vin>, Google's SDV report on telemetry-aaos-sdv.<vin>.
func TestTelemetrySubjectIsFamilyThenVin(t *testing.T) {
	v := &VehicleClient{VIN: "VIN1"}
	if got := v.buildTelemetrySubject(); got != "telemetry.VIN1" {
		t.Errorf("TelemetryMessage subject = %q, want telemetry.VIN1", got)
	}
}

func TestMetricsReportSubjectIsTheAaosSdvFamily(t *testing.T) {
	v := &VehicleClient{VIN: "VIN1"}
	if got := v.buildMetricsReportSubject(); got != "telemetry-aaos-sdv.VIN1" {
		t.Errorf("MetricsReport subject = %q, want telemetry-aaos-sdv.VIN1", got)
	}
}

// Until 2026-10-09 TELEMETRY_PREFIX moved the Nexus message into the family that carries
// Google's report. The variable no longer has an effect.
func TestTelemetryPrefixNoLongerChangesTheFamily(t *testing.T) {
	t.Setenv("TELEMETRY_PREFIX", "prod.bigtable")
	v := &VehicleClient{VIN: "VIN1"}
	if got := v.buildTelemetrySubject(); got != "telemetry.VIN1" {
		t.Errorf("with TELEMETRY_PREFIX set the subject = %q, want telemetry.VIN1", got)
	}
}
