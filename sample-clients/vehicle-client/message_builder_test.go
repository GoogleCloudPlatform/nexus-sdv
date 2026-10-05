package main

import (
	"strings"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"

	pb "github.com/valtech-sdv/vehicle-client/telemetry"
	pbVehicle "github.com/valtech-sdv/vehicle-client/telemetry"
)

func testSimulator() *VehicleSimulator {
	return &VehicleSimulator{
		BatteryVoltage: 12.34,
		BatteryCurrent: 45.67,
		BatterySoC:     85.55,
		BatteryTemp:    25.25,
		EnginePower:    50.5,
		EngineRPM:      1234,
		FuelLevel:      42.1,
		Velocity:       88.8,
		SteeringAngle:  -12.5,
		AcceleratorPct: 30.0,
		BrakePct:       0.0,
	}
}

func TestBuildTelemetryMessage(t *testing.T) {
	sim := testSimulator()
	now := time.Now()

	msg := buildTelemetryMessage(sim, "VIN123", now)

	if msg.DeviceId != "VIN123" {
		t.Errorf("DeviceId = %q, want VIN123", msg.DeviceId)
	}
	if len(msg.SensorData) != 4 {
		t.Fatalf("len(SensorData) = %d, want 4", len(msg.SensorData))
	}

	want := map[string]string{
		"battery.voltage": "12.34",
		"battery.current": "45.67",
		"battery.soc":     "85.55",
		"battery.temp":    "25.25",
	}
	for _, reading := range msg.SensorData {
		wantValue, ok := want[reading.Sensor]
		if !ok {
			t.Errorf("unexpected sensor name: %q", reading.Sensor)
			continue
		}
		if reading.Value != wantValue {
			t.Errorf("sensor %q value = %q, want %q", reading.Sensor, reading.Value, wantValue)
		}
		if reading.DataType != pb.DataType_DYNAMIC {
			t.Errorf("sensor %q DataType = %v, want DYNAMIC", reading.Sensor, reading.DataType)
		}
	}
}

func TestBuildMetricsReportFieldMapping(t *testing.T) {
	sim := testSimulator()
	now := time.Now()

	report, err := buildMetricsReport(sim, 7, now)
	if err != nil {
		t.Fatalf("buildMetricsReport returned error: %v", err)
	}

	if report.ReportNumber != 7 {
		t.Errorf("ReportNumber = %d, want 7", report.ReportNumber)
	}

	var vehicleData pbVehicle.VehicleTelemetryData
	if err := report.ReportData.UnmarshalTo(&vehicleData); err != nil {
		t.Fatalf("failed to unmarshal ReportData: %v", err)
	}

	if vehicleData.ENGINE_POWER != float32(sim.EnginePower) {
		t.Errorf("ENGINE_POWER = %v, want %v", vehicleData.ENGINE_POWER, sim.EnginePower)
	}
	if vehicleData.VELOCITY != float32(sim.Velocity) {
		t.Errorf("VELOCITY = %v, want %v", vehicleData.VELOCITY, sim.Velocity)
	}
	if vehicleData.IGNITION_STATE == nil || *vehicleData.IGNITION_STATE != true {
		t.Errorf("IGNITION_STATE = %v, want true (EngineRPM > 0)", vehicleData.IGNITION_STATE)
	}
	if vehicleData.VehicleDynamics.SteeringAngleDeg != sim.SteeringAngle {
		t.Errorf("SteeringAngleDeg = %v, want %v", vehicleData.VehicleDynamics.SteeringAngleDeg, sim.SteeringAngle)
	}
}

func TestBuildMetricsReportIgnitionOffWhenEngineStopped(t *testing.T) {
	sim := testSimulator()
	sim.EngineRPM = 0

	report, err := buildMetricsReport(sim, 1, time.Now())
	if err != nil {
		t.Fatalf("buildMetricsReport returned error: %v", err)
	}

	var vehicleData pbVehicle.VehicleTelemetryData
	if err := report.ReportData.UnmarshalTo(&vehicleData); err != nil {
		t.Fatalf("failed to unmarshal ReportData: %v", err)
	}
	if vehicleData.IGNITION_STATE == nil || *vehicleData.IGNITION_STATE != false {
		t.Errorf("IGNITION_STATE = %v, want false when EngineRPM == 0", vehicleData.IGNITION_STATE)
	}
}

func TestBuildPayloadTelemetry(t *testing.T) {
	v := &VehicleClient{VIN: "VIN123", MessageType: "telemetry"}
	sim := testSimulator()

	subject, payload, err := buildPayload(v, sim, 1, time.Now())
	if err != nil {
		t.Fatalf("buildPayload returned error: %v", err)
	}
	if subject != "telemetry.VIN123.battery" {
		t.Errorf("subject = %q, want telemetry.VIN123.battery", subject)
	}

	var msg pb.TelemetryMessage
	if err := proto.Unmarshal(payload, &msg); err != nil {
		t.Fatalf("payload did not unmarshal as TelemetryMessage: %v", err)
	}
}

func TestBuildPayloadMetricsReport(t *testing.T) {
	v := &VehicleClient{VIN: "VIN123", MessageType: "metrics_report"}
	sim := testSimulator()

	subject, payload, err := buildPayload(v, sim, 3, time.Now())
	if err != nil {
		t.Fatalf("buildPayload returned error: %v", err)
	}
	if !strings.Contains(subject, "VIN123") {
		t.Errorf("subject = %q, want it to contain VIN123", subject)
	}

	var report pb.MetricsReport
	if err := proto.Unmarshal(payload, &report); err != nil {
		t.Fatalf("payload did not unmarshal as MetricsReport: %v", err)
	}
	if report.ReportNumber != 3 {
		t.Errorf("ReportNumber = %d, want 3", report.ReportNumber)
	}
}

func TestBuildPayloadUnknownMessageType(t *testing.T) {
	v := &VehicleClient{VIN: "VIN123", MessageType: "bogus"}
	sim := testSimulator()

	_, _, err := buildPayload(v, sim, 1, time.Now())
	if err == nil {
		t.Fatal("expected an error for unknown message type, got nil")
	}
}
