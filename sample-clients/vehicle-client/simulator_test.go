package main

import "testing"

func TestClamp(t *testing.T) {
	tests := []struct {
		name      string
		v, lo, hi float64
		want      float64
	}{
		{"within range", 5, 0, 10, 5},
		{"below min", -1, 0, 10, 0},
		{"above max", 11, 0, 10, 10},
		{"equal to min", 0, 0, 10, 0},
		{"equal to max", 10, 0, 10, 10},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := clamp(tt.v, tt.lo, tt.hi); got != tt.want {
				t.Errorf("clamp(%v, %v, %v) = %v, want %v", tt.v, tt.lo, tt.hi, got, tt.want)
			}
		})
	}
}

func TestVehicleSimulatorTickStaysInRange(t *testing.T) {
	sim := NewVehicleSimulator()

	for i := 0; i < 10000; i++ {
		sim.Tick()

		if sim.BatteryVoltage < 11.0 || sim.BatteryVoltage > 14.5 {
			t.Fatalf("BatteryVoltage out of range: %v", sim.BatteryVoltage)
		}
		if sim.BatteryCurrent < 0 || sim.BatteryCurrent > 100 {
			t.Fatalf("BatteryCurrent out of range: %v", sim.BatteryCurrent)
		}
		if sim.BatteryTemp < 15 || sim.BatteryTemp > 45 {
			t.Fatalf("BatteryTemp out of range: %v", sim.BatteryTemp)
		}
		if sim.EnginePower < 0 || sim.EnginePower > 150 {
			t.Fatalf("EnginePower out of range: %v", sim.EnginePower)
		}
		if sim.EngineRPM < 0 || sim.EngineRPM > 6000 {
			t.Fatalf("EngineRPM out of range: %v", sim.EngineRPM)
		}
		if sim.Velocity < 0 || sim.Velocity > 200 {
			t.Fatalf("Velocity out of range: %v", sim.Velocity)
		}
		if sim.SteeringAngle < -45 || sim.SteeringAngle > 45 {
			t.Fatalf("SteeringAngle out of range: %v", sim.SteeringAngle)
		}
		if sim.AcceleratorPct < 0 || sim.AcceleratorPct > 100 {
			t.Fatalf("AcceleratorPct out of range: %v", sim.AcceleratorPct)
		}
		if sim.BrakePct < 0 || sim.BrakePct > 100 {
			t.Fatalf("BrakePct out of range: %v", sim.BrakePct)
		}
	}
}

func TestVehicleSimulatorTickResetsBatterySoC(t *testing.T) {
	sim := NewVehicleSimulator()
	sim.BatterySoC = 9.5

	sim.Tick()

	if sim.BatterySoC != 90.0 {
		t.Errorf("BatterySoC = %v, want reset to 90.0", sim.BatterySoC)
	}
}

func TestVehicleSimulatorTickResetsFuelLevel(t *testing.T) {
	sim := NewVehicleSimulator()
	sim.FuelLevel = 4.5

	sim.Tick()

	if sim.FuelLevel != 60.0 {
		t.Errorf("FuelLevel = %v, want reset to 60.0", sim.FuelLevel)
	}
}
