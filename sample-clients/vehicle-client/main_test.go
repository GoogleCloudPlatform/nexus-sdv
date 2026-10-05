package main

import (
	"encoding/base64"
	"testing"
	"time"
)

// encodeSegment base64url-encodes a raw payload the way a real JWT does, so we
// can hand jwtExpiry a token whose middle segment it will actually decode.
// jwtExpiry decodes with base64.RawURLEncoding, so we must encode with its twin.
func encodeSegment(raw string) string {
	return base64.RawURLEncoding.EncodeToString([]byte(raw))
}

func TestJwtExpiry(t *testing.T) {
	// A fixed instant keeps the happy-path assertion deterministic — no time.Now().
	want := time.Unix(1700000000, 0)

	// Table-driven test: each case is a row of data. This is THE idiomatic Go
	// pattern for parameterized tests — a plain slice of structs, no framework.
	tests := []struct {
		name  string
		token string
		want  time.Time // the zero value, time.Time{}, means "expect the zero time"
	}{
		{
			name:  "happy path returns exp",
			token: "header." + encodeSegment(`{"exp":1700000000}`) + ".sig",
			want:  want,
		},
		{
			name:  "wrong number of segments",
			token: "only.two",
			want:  time.Time{},
		},
		{
			name:  "middle segment is not valid base64url",
			token: "header.!!!not base64!!!.sig",
			want:  time.Time{},
		},
		{
			name:  "payload is not valid JSON",
			token: "header." + encodeSegment(`not json`) + ".sig",
			want:  time.Time{},
		},
		{
			name:  "exp claim missing",
			token: "header." + encodeSegment(`{"sub":"car"}`) + ".sig",
			want:  time.Time{},
		},
		{
			name:  "exp claim is not a number",
			token: "header." + encodeSegment(`{"exp":"soon"}`) + ".sig",
			want:  time.Time{},
		},
	}

	for _, tt := range tests {
		// t.Run gives each case its own name in the output and lets you run one
		// in isolation: go test -run TestJwtExpiry/exp_claim_missing
		t.Run(tt.name, func(t *testing.T) {
			got := jwtExpiry(tt.token)
			// Compare times with .Equal, never ==. time.Time carries a monotonic
			// clock reading and a location; == compares those too and can report
			// "not equal" for two instants that represent the same moment.
			if !got.Equal(tt.want) {
				t.Errorf("jwtExpiry(%q) = %v, want %v", tt.token, got, tt.want)
			}
		})
	}
}
