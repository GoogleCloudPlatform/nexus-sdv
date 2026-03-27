package egress

import (
	"context"
	"fmt"

	"github.com/nats-io/nats.go"
	"go.uber.org/zap"
)

// Publisher defines the interface for publishing transformed messages.
type Publisher interface {
	Publish(ctx context.Context, subject string, data []byte) error
	Close() error
}

// NATSPublisher publishes serialized TelemetryMessages to NATS.
type NATSPublisher struct {
	conn   *nats.Conn
	logger *zap.Logger
}

// NATSConfig holds NATS connection configuration.
type NATSConfig struct {
	URL   string
	Token string
}

// NewNATSPublisher connects to NATS and returns a publisher.
func NewNATSPublisher(cfg NATSConfig, logger *zap.Logger) (*NATSPublisher, error) {
	opts := []nats.Option{
		nats.Name("data-converter"),
		nats.MaxReconnects(-1),
		nats.ReconnectHandler(func(c *nats.Conn) {
			logger.Info("reconnected to NATS", zap.String("url", c.ConnectedUrl()))
		}),
		nats.DisconnectErrHandler(func(_ *nats.Conn, err error) {
			logger.Warn("disconnected from NATS", zap.Error(err))
		}),
	}

	if cfg.Token != "" {
		opts = append(opts, nats.Token(cfg.Token))
	}

	conn, err := nats.Connect(cfg.URL, opts...)
	if err != nil {
		return nil, fmt.Errorf("nats connect: %w", err)
	}

	logger.Info("connected to NATS", zap.String("url", cfg.URL))
	return &NATSPublisher{conn: conn, logger: logger.Named("nats")}, nil
}

func (p *NATSPublisher) Publish(_ context.Context, subject string, data []byte) error {
	if err := p.conn.Publish(subject, data); err != nil {
		return fmt.Errorf("nats publish to %s: %w", subject, err)
	}
	p.logger.Debug("published", zap.String("subject", subject), zap.Int("bytes", len(data)))
	return nil
}

func (p *NATSPublisher) Close() error {
	p.conn.Close()
	p.logger.Info("NATS connection closed")
	return nil
}
