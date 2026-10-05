package main

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"
)

// newMTLSClient builds an http.Client configured for mutual TLS: it
// presents cert to the server and trusts the CA at caCertPath.
// clientCertLogLabel is logged when the server requests the client
// certificate (e.g. "Server" or "Keycloak"), to keep the two connections
// distinguishable in logs.
//
// resolveIP, when non-empty, makes the client dial that address instead of
// resolving the URL's hostname — for guests with no DNS resolver at all (see
// dialContextResolving). SNI and certificate validation still use the real
// hostname. Empty means normal resolution.
func newMTLSClient(cert tls.Certificate, caCertPath string, insecureSkipVerify bool, clientCertLogLabel string, resolveIP string) (*http.Client, error) {
	caCert, err := os.ReadFile(caCertPath)
	if err != nil {
		return nil, fmt.Errorf("failed to load CA certificate from %s: %w", caCertPath, err)
	}
	// Start from the system roots rather than an empty pool. Under remote PKI
	// Keycloak is served by the Ingress with a publicly trusted certificate, so a
	// pool holding only Nexus's private CA rejects it with "certificate signed by
	// unknown authority". The private CA is still appended below — the
	// registration server keeps using it, and under local PKI so does Keycloak.
	caCertPool, err := x509.SystemCertPool()
	if err != nil || caCertPool == nil {
		log.Printf("  system certificate pool unavailable (%v) — trusting only %s", err, caCertPath)
		caCertPool = x509.NewCertPool()
	}
	caCertPool.AppendCertsFromPEM(caCert)

	tlsConfig := &tls.Config{
		Certificates:       []tls.Certificate{cert},
		InsecureSkipVerify: insecureSkipVerify,
		RootCAs:            caCertPool,
		MinVersion:         tls.VersionTLS12,
		MaxVersion:         tls.VersionTLS13,
		// Use classic key exchange curves to avoid post-quantum compatibility issues
		// between Go's crypto/tls and rustls's X25519MLKEM768 implementation
		CurvePreferences: []tls.CurveID{tls.X25519, tls.CurveP256, tls.CurveP384},
		// Force client certificate to be sent
		GetClientCertificate: func(info *tls.CertificateRequestInfo) (*tls.Certificate, error) {
			log.Printf("  %s requested client certificate", clientCertLogLabel)
			return &cert, nil
		},
	}

	return &http.Client{
		Transport: &http.Transport{
			TLSClientConfig: tlsConfig,
			DialContext:     dialContextResolving(resolveIP),
		},
		Timeout:   30 * time.Second,
	}, nil
}
