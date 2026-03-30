package mqtt

import (
	"context"
	"fmt"
	"time"

	"data-converter/src/ingress"

	mqtt "github.com/eclipse/paho.mqtt.golang"
	"go.uber.org/zap"
	"gopkg.in/yaml.v3"
)

func init() {
	ingress.Register("mqtt", Factory)
}

// Factory creates an MQTT adapter from raw YAML config.
func Factory(rawCfg yaml.Node, sources []ingress.ConverterSource, logger *zap.Logger) (ingress.Adapter, error) {
	var cfg Config
	if err := rawCfg.Decode(&cfg); err != nil {
		return nil, fmt.Errorf("mqtt: parse config: %w", err)
	}

	for _, s := range sources {
		cfg.Topics = append(cfg.Topics, TopicConfig{Topic: s.Topic, QoS: s.QoS})
	}

	return New(cfg, logger), nil
}

// Config holds MQTT-specific adapter configuration.
type Config struct {
	Broker   string     `yaml:"broker"`
	ClientID string     `yaml:"client_id"`
	Auth     AuthConfig `yaml:"auth"`
	Topics   []TopicConfig
	// BufferSize is the capacity of the internal message channel.
	BufferSize int `yaml:"buffer_size"`
}

// AuthConfig holds MQTT authentication credentials.
type AuthConfig struct {
	Username string `yaml:"username"`
	Password string `yaml:"password"`
}

// TopicConfig defines a single MQTT subscription.
type TopicConfig struct {
	Topic string
	QoS   byte
}

// Adapter implements ingress.Adapter for MQTT.
type Adapter struct {
	cfg    Config
	client mqtt.Client
	msgs   chan ingress.RawMessage
	logger *zap.Logger
}

// New creates a new MQTT adapter.
func New(cfg Config, logger *zap.Logger) *Adapter {
	if cfg.BufferSize <= 0 {
		cfg.BufferSize = 1000
	}
	return &Adapter{
		cfg:    cfg,
		msgs:   make(chan ingress.RawMessage, cfg.BufferSize),
		logger: logger.Named("mqtt"),
	}
}

func (a *Adapter) Start(ctx context.Context) error {
	opts := mqtt.NewClientOptions().
		AddBroker(a.cfg.Broker).
		SetClientID(a.cfg.ClientID).
		SetAutoReconnect(true).
		SetConnectRetry(true).
		SetConnectRetryInterval(5 * time.Second).
		SetOrderMatters(false).
		SetOnConnectHandler(a.onConnect).
		SetConnectionLostHandler(func(_ mqtt.Client, err error) {
			a.logger.Warn("connection lost", zap.Error(err))
		})

	if a.cfg.Auth.Username != "" {
		opts.SetUsername(a.cfg.Auth.Username)
		opts.SetPassword(a.cfg.Auth.Password)
	}

	a.client = mqtt.NewClient(opts)
	token := a.client.Connect()
	token.Wait()
	if err := token.Error(); err != nil {
		return fmt.Errorf("mqtt connect: %w", err)
	}

	a.logger.Info("connected to broker", zap.String("broker", a.cfg.Broker))
	return nil
}

// onConnect subscribes to configured topics. Called on initial connect and reconnect.
func (a *Adapter) onConnect(c mqtt.Client) {
	for _, t := range a.cfg.Topics {
		qos := t.QoS
		topic := t.Topic
		token := c.Subscribe(topic, qos, a.handleMessage)
		token.Wait()
		if err := token.Error(); err != nil {
			a.logger.Error("subscribe failed", zap.String("topic", topic), zap.Error(err))
			continue
		}
		a.logger.Info("subscribed", zap.String("topic", topic), zap.Uint8("qos", qos))
	}
}

// handleMessage is the MQTT message callback. It pushes messages into the channel,
// dropping the oldest message if the buffer is full (backpressure).
func (a *Adapter) handleMessage(_ mqtt.Client, msg mqtt.Message) {
	raw := ingress.RawMessage{
		Source:  "mqtt",
		Topic:   msg.Topic(),
		Payload: msg.Payload(),
		Metadata: map[string]string{
			"mqtt.qos":       fmt.Sprintf("%d", msg.Qos()),
			"mqtt.retained":  fmt.Sprintf("%t", msg.Retained()),
			"mqtt.messageID": fmt.Sprintf("%d", msg.MessageID()),
		},
	}

	select {
	case a.msgs <- raw:
	default:
		// Buffer full — drop oldest, then enqueue
		select {
		case <-a.msgs:
			a.logger.Warn("buffer full, dropped oldest message")
		default:
		}
		// Best-effort enqueue after drop
		select {
		case a.msgs <- raw:
		default:
			a.logger.Warn("failed to enqueue message after drop")
		}
	}
}

func (a *Adapter) Stop(_ context.Context) error {
	if a.client != nil && a.client.IsConnected() {
		a.client.Disconnect(1000)
		a.logger.Info("disconnected from broker")
	}
	close(a.msgs)
	return nil
}

func (a *Adapter) Messages() <-chan ingress.RawMessage {
	return a.msgs
}
