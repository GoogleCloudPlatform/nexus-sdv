package main

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestValidateAccepts(t *testing.T) {
	ok := []eventRequest{
		{VIN: "VEHICLE001", Source: "factory-helper", Action: "factory-certificate-issued", Result: "success"},
		{VIN: "a", Source: "registration", Action: "operational-certificate-issued", Result: "failure"},
		{VIN: "WVW-ZZZ-1K-Z4W123456", Source: "registration", Action: "operational-certificate-issued", Result: "success"},
		{VIN: "81a104d69bec", Source: "factory-helper", Action: "factory-certificate-issued", Result: "success", Detail: "issued by factory-helper"},
	}
	for _, e := range ok {
		if err := e.validate(); err != nil {
			t.Errorf("expected %+v to be accepted, got %v", e, err)
		}
	}
}

func TestValidateRejects(t *testing.T) {
	base := func() eventRequest {
		return eventRequest{VIN: "VEHICLE001", Source: "factory-helper", Action: "factory-certificate-issued", Result: "success"}
	}
	cases := map[string]func(*eventRequest){
		"empty vin":       func(e *eventRequest) { e.VIN = "" },
		"vin too long":    func(e *eventRequest) { e.VIN = "123456789012345678901234567890123" },
		"vin with space":  func(e *eventRequest) { e.VIN = "VEHICLE 001" },
		"vin with slash":  func(e *eventRequest) { e.VIN = "../etc/passwd" },
		"vin with quote":  func(e *eventRequest) { e.VIN = "VIN';DROP TABLE vin_events;--" },
		"unknown source":  func(e *eventRequest) { e.Source = "some-other-service" },
		"empty source":    func(e *eventRequest) { e.Source = "" },
		"unknown action":  func(e *eventRequest) { e.Action = "certificate-revoked" },
		"unknown result":  func(e *eventRequest) { e.Result = "maybe" },
		"detail too long": func(e *eventRequest) { e.Detail = string(make([]byte, 513)) },
	}
	for name, mutate := range cases {
		e := base()
		mutate(&e)
		if err := e.validate(); err == nil {
			t.Errorf("%s: expected rejection, got none (%+v)", name, e)
		}
	}
}

// A 32-character VIN is the documented boundary and must still be accepted.
func TestValidateBoundary(t *testing.T) {
	e := eventRequest{
		VIN:    "12345678901234567890123456789012",
		Source: "registration", Action: "operational-certificate-issued", Result: "success",
	}
	if err := e.validate(); err != nil {
		t.Errorf("32-character vin should be accepted, got %v", err)
	}
}

// --- GET /v1/vins/{vin}/events -------------------------------------------
// The handler validates the path value before it touches the database, so the
// rejection path is exercised here with no database at all. The rows it returns
// for a valid VIN need one, and are covered a layer up in the web client's
// tests.

func TestEventsRejectsMalformedVIN(t *testing.T) {
	bad := []string{
		"",                              // empty
		"VIN WITH SPACE",                // whitespace
		"VIN';DROP TABLE vin_events;--", // injection attempt
		strings.Repeat("A", 33),         // one over the limit
		"vin/../../etc/passwd",          // traversal attempt
	}
	for _, vin := range bad {
		req := httptest.NewRequest("GET", "/v1/vins/"+url.PathEscape(vin)+"/events", nil)
		req.SetPathValue("vin", vin)
		rec := httptest.NewRecorder()

		// db is nil on purpose: reaching it would be the failure this test is for.
		(&server{}).listEvents(rec, req)

		if rec.Code != http.StatusBadRequest {
			t.Errorf("vin %q: expected 400, got %d", vin, rec.Code)
		}
	}
}

func TestEventsAcceptsWellFormedVIN(t *testing.T) {
	// A well-formed VIN must get past validation — proven by it reaching the
	// database and failing there, rather than being rejected as malformed.
	req := httptest.NewRequest("GET", "/v1/vins/VEHICLE001/events", nil)
	req.SetPathValue("vin", "VEHICLE001")
	rec := httptest.NewRecorder()

	defer func() { _ = recover() }() // a nil db may panic; a 400 is the failure
	(&server{}).listEvents(rec, req)

	if rec.Code == http.StatusBadRequest {
		t.Error("a well-formed VIN was rejected as malformed")
	}
}
