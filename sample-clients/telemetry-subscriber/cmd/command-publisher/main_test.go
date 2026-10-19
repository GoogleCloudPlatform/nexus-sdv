package main

import (
	"testing"
)

func TestBuildCommand(t *testing.T) {
	c := buildCommand("WBA123", "door_lock", true)

	if c.VehicleId != "WBA123" {
		t.Errorf("VehicleId = %q, want WBA123", c.VehicleId)
	}
	if c.RequestId == "" {
		t.Error("RequestId must be set")
	}
	if c.Timestamp == nil {
		t.Error("Timestamp must be set")
	}
	ac := c.GetActuatorCommand()
	if ac == nil {
		t.Fatal("payload must be ActuatorCommand")
	}
	if ac.ActuatorId != "door_lock" {
		t.Errorf("ActuatorId = %q, want door_lock", ac.ActuatorId)
	}
	if ac.GetBoolValue() != true {
		t.Error("BoolValue must be true")
	}
}

func TestCommandSubject(t *testing.T) {
	if got := commandSubject("WBA123"); got != "commands.WBA123.actuator" {
		t.Errorf("subject = %q, want commands.WBA123.actuator", got)
	}
}
