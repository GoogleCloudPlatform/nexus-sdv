package main

import (
	"strings"
	"testing"
)

// The callout logs its connection details at DEBUG on every start. The URL the chart hands
// it carries the password in the userinfo part; the log line must not.
func TestConnectionDetailsNeverContainThePassword(t *testing.T) {
	got := redactURL("nats://auth-callout-service:s3cr3t-value@nats:4222")
	if strings.Contains(got, "s3cr3t-value") {
		t.Fatalf("password leaked into the log line: %q", got)
	}
	if got != "nats://nats:4222" {
		t.Fatalf("want the URL without userinfo, got %q", got)
	}
}

func TestRedactURLLeavesACredentialFreeURLAlone(t *testing.T) {
	if got := redactURL("nats://nats:4222"); got != "nats://nats:4222" {
		t.Fatalf("got %q", got)
	}
}

func TestRedactURLNeverEchoesAnUnparseableValue(t *testing.T) {
	got := redactURL("nats://user:pa ss@nats:4222")
	if strings.Contains(got, "pa ss") {
		t.Fatalf("unparseable URL echoed verbatim: %q", got)
	}
}
