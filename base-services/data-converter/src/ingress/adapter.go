package ingress

import "context"

// Adapter defines the interface for protocol-specific ingress adapters.
// Each adapter connects to an external source, consumes messages, and forwards
// them as RawMessages through a channel.
type Adapter interface {
	// Start begins consuming messages from the source.
	Start(ctx context.Context) error
	// Stop gracefully shuts down the adapter.
	Stop(ctx context.Context) error
	// Messages returns a read-only channel of incoming raw messages.
	Messages() <-chan RawMessage
}

// RawMessage represents an unprocessed message received from an ingress adapter.
type RawMessage struct {
	Source   string            // Protocol source identifier, e.g. "mqtt", "http"
	Topic    string            // Source topic/subject/endpoint
	Payload  []byte            // Raw payload bytes
	Metadata map[string]string // Additional protocol-specific metadata
}
