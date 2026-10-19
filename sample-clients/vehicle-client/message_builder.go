package main

import (
	"fmt"
	"time"

	"github.com/google/uuid"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/anypb"
	"google.golang.org/protobuf/types/known/timestamppb"

	pb "github.com/valtech-sdv/vehicle-client/telemetry"
	pbMetrics "github.com/valtech-sdv/vehicle-client/telemetry"
	pbVehicle "github.com/valtech-sdv/vehicle-client/telemetry"
)

// buildTelemetryMessage builds a TelemetryMessage from the simulator's current values.
func buildTelemetryMessage(sim *VehicleSimulator, vin string, now time.Time) *pb.TelemetryMessage {
	return &pb.TelemetryMessage{
		MessageId:     uuid.New().String(),
		SchemaVersion: 1,
		DeviceId:      vin,
		SensorData: []*pb.SensorReading{
			{
				Timestamp: timestamppb.New(now),
				Value:     fmt.Sprintf("%.2f", sim.BatteryVoltage),
				DataType:  pb.DataType_DYNAMIC,
				Sensor:    "battery.voltage",
			},
			{
				Timestamp: timestamppb.New(now),
				Value:     fmt.Sprintf("%.2f", sim.BatteryCurrent),
				DataType:  pb.DataType_DYNAMIC,
				Sensor:    "battery.current",
			},
			{
				Timestamp: timestamppb.New(now),
				Value:     fmt.Sprintf("%.2f", sim.BatterySoC),
				DataType:  pb.DataType_DYNAMIC,
				Sensor:    "battery.soc",
			},
			{
				Timestamp: timestamppb.New(now),
				Value:     fmt.Sprintf("%.2f", sim.BatteryTemp),
				DataType:  pb.DataType_DYNAMIC,
				Sensor:    "battery.temp",
			},
		},
	}
}

// buildMetricsReport builds a MetricsReport wrapping VehicleTelemetryData from
// the simulator's current values.
func buildMetricsReport(sim *VehicleSimulator, reportNumber int, now time.Time) (*pbMetrics.MetricsReport, error) {
	ignitionState := sim.EngineRPM > 0
	gpsLat := float32(0.0)
	gpsLon := float32(0.0)

	// Every field the simulator has a value for is set, zero included: the report type marks
	// its scalars optional, so an unset field means "not reported" and 0 means 0.
	vehicleData := &pbVehicle.VehicleTelemetryData{
		ENGINE_POWER:   proto.Float32(float32(sim.EnginePower)),
		ENGINE_RPM:     proto.Float32(float32(sim.EngineRPM)),
		FUEL_CAPACITY:  proto.Float32(50.0), // Static value
		FUEL_LEVEL:     proto.Float32(float32(sim.FuelLevel)),
		TIRE_PRESSURE:  proto.Float32(2.2), // Static value
		VELOCITY:       proto.Float32(float32(sim.Velocity)),
		IGNITION_STATE: &ignitionState,
		GPS_LATITUDE:   &gpsLat,
		GPS_LONGITUDE:  &gpsLon,
		VehicleDynamics: &pbVehicle.CarlaVehicleDynamics{
			SteeringAngleDeg:    proto.Float64(sim.SteeringAngle),
			AcceleratorPedalPct: proto.Float64(sim.AcceleratorPct),
			BrakePedalPct:       proto.Float64(sim.BrakePct),
		},
		GearStatus: &pbVehicle.CurrentGear{
			Gear: pbVehicle.CurrentGear_N.Enum(),
		},
	}

	anyPayload, err := anypb.New(vehicleData)
	if err != nil {
		return nil, fmt.Errorf("failed to create Any payload: %w", err)
	}

	return &pbMetrics.MetricsReport{
		ReportNumber:         int32(reportNumber),
		ReportTimestamp:      timestamppb.New(now),
		ReportReason:         pbMetrics.MetricsReport_REGULAR,
		MetricsConfigUuid:    uuid.New().String(),
		MetricsConfigVersion: 1,
		ReportConfigName:     "default",
		ReportData:           anyPayload,
		ReportUuid:           uuid.New().String(),
	}, nil
}

// buildPayload selects the NATS subject and wire-encoded payload for the
// client's configured MessageType.
func buildPayload(v *VehicleClient, sim *VehicleSimulator, reportNumber int, now time.Time) (subject string, payload []byte, err error) {
	switch v.MessageType {
	case "telemetry":
		subject = v.buildTelemetrySubject()
		payload, err = proto.Marshal(buildTelemetryMessage(sim, v.VIN, now))
		if err != nil {
			return "", nil, fmt.Errorf("failed to marshal TelemetryMessage: %w", err)
		}
		return subject, payload, nil

	case "metrics_report":
		subject = v.buildMetricsReportSubject()
		report, err := buildMetricsReport(sim, reportNumber, now)
		if err != nil {
			return "", nil, fmt.Errorf("failed to build MetricsReport: %w", err)
		}
		payload, err = proto.Marshal(report)
		if err != nil {
			return "", nil, fmt.Errorf("failed to marshal MetricsReport: %w", err)
		}
		return subject, payload, nil

	default:
		return "", nil, fmt.Errorf("unknown message type: %s", v.MessageType)
	}
}
