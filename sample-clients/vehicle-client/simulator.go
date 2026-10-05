package main

import mathrand "math/rand"

// VehicleSimulator holds the battery/engine state used to generate
// realistic-looking telemetry values for the sample publisher.
type VehicleSimulator struct {
	BatteryVoltage float64
	BatteryCurrent float64
	BatterySoC     float64
	BatteryTemp    float64

	EnginePower    float64
	EngineRPM      float64
	FuelLevel      float64
	Velocity       float64
	SteeringAngle  float64
	AcceleratorPct float64
	BrakePct       float64
}

// NewVehicleSimulator returns a simulator seeded with realistic starting values.
func NewVehicleSimulator() *VehicleSimulator {
	return &VehicleSimulator{
		BatteryVoltage: 12.6,
		BatteryCurrent: 45.2,
		BatterySoC:     85.5,
		BatteryTemp:    25.3,
		EnginePower:    50.0,
		EngineRPM:      1000.0,
		FuelLevel:      50.0,
	}
}

func clamp(v, min, max float64) float64 {
	if v < min {
		return min
	}
	if v > max {
		return max
	}
	return v
}

// Tick advances the simulation by one interval: applies random variation to
// every field, then clamps each into its realistic range.
func (s *VehicleSimulator) Tick() {
	// Simulate realistic battery variations
	s.BatteryVoltage = clamp(s.BatteryVoltage+(mathrand.Float64()-0.5)*0.2, 11.0, 14.5) // ±0.1V
	s.BatteryCurrent = clamp(s.BatteryCurrent+(mathrand.Float64()-0.5)*5.0, 0, 100)     // ±2.5A
	s.BatterySoC -= mathrand.Float64() * 0.1                                            // Slowly discharge
	if s.BatterySoC < 10 {
		s.BatterySoC = 90.0 // Reset to charged state
	}
	s.BatteryTemp = clamp(s.BatteryTemp+(mathrand.Float64()-0.5)*1.0, 15, 45) // ±0.5°C

	// Simulate engine variations (for metrics reports)
	s.EnginePower = clamp(s.EnginePower+(mathrand.Float64()-0.5)*10.0, 0, 150)
	s.EngineRPM = clamp(s.EngineRPM+(mathrand.Float64()-0.5)*100.0, 0, 6000)
	s.FuelLevel -= mathrand.Float64() * 0.05 // Slowly consume fuel
	if s.FuelLevel < 5 {
		s.FuelLevel = 60 // Reset fuel
	}
	s.Velocity = clamp(s.Velocity+(mathrand.Float64()-0.5)*100.0, 0, 200)
	s.SteeringAngle = clamp(s.SteeringAngle+(mathrand.Float64()-0.5)*2.0, -45, 45)
	s.AcceleratorPct = clamp(s.AcceleratorPct+(mathrand.Float64()-0.5)*5.0, 0, 100)
	s.BrakePct = clamp(s.BrakePct+(mathrand.Float64()-0.5)*5.0, 0, 100)
}
