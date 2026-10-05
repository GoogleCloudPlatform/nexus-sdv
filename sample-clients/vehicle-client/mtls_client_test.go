package main

import (
	"crypto/tls"
	"net/http"
	"os"
	"path/filepath"
	"testing"
)

func TestNewMTLSClientConfiguresTLS(t *testing.T) {
	caPath := filepath.Join(t.TempDir(), "ca.pem")
	if err := os.WriteFile(caPath, []byte("-----BEGIN CERTIFICATE-----\nnotarealcert\n-----END CERTIFICATE-----\n"), 0644); err != nil {
		t.Fatalf("failed to write temp CA file: %v", err)
	}

	cert := tls.Certificate{Certificate: [][]byte{[]byte("fake-cert-bytes")}}

	client, err := newMTLSClient(cert, caPath, true, "Test", "")
	if err != nil {
		t.Fatalf("newMTLSClient returned error: %v", err)
	}

	transport, ok := client.Transport.(*http.Transport)
	if !ok {
		t.Fatalf("client.Transport is %T, want *http.Transport", client.Transport)
	}
	tlsConfig := transport.TLSClientConfig

	if !tlsConfig.InsecureSkipVerify {
		t.Error("InsecureSkipVerify = false, want true")
	}
	if tlsConfig.MinVersion != tls.VersionTLS12 {
		t.Errorf("MinVersion = %v, want TLS 1.2", tlsConfig.MinVersion)
	}
	if tlsConfig.MaxVersion != tls.VersionTLS13 {
		t.Errorf("MaxVersion = %v, want TLS 1.3", tlsConfig.MaxVersion)
	}

	got, err := tlsConfig.GetClientCertificate(nil)
	if err != nil {
		t.Fatalf("GetClientCertificate returned error: %v", err)
	}
	if len(got.Certificate) != 1 || string(got.Certificate[0]) != "fake-cert-bytes" {
		t.Errorf("GetClientCertificate returned %v, want the cert passed to newMTLSClient", got)
	}
}

func TestNewMTLSClientMissingCAFile(t *testing.T) {
	_, err := newMTLSClient(tls.Certificate{}, filepath.Join(t.TempDir(), "does-not-exist.pem"), false, "Test", "")
	if err == nil {
		t.Fatal("expected an error for a missing CA file, got nil")
	}
}
