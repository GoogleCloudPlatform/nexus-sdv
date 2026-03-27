package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"

	telemetry "data-converter/api/gen/telemetry"
	"data-converter/src/adapter"
	"data-converter/src/adapter/mqtt"
	"data-converter/src/egress"
	"data-converter/src/transform"

	"go.uber.org/zap"
	"google.golang.org/protobuf/proto"
)

func main() {
	// --- Config ---
	configPath := os.Getenv("CONFIG_PATH")
	if configPath == "" {
		log.Fatal("CONFIG_PATH environment variable is required")
	}

	cfg, err := LoadConfig(configPath)
	if err != nil {
		log.Fatalf("failed to load config: %v", err)
	}

	// --- Logger ---
	var logger *zap.Logger
	if cfg.Service.LogLevel == "debug" {
		logger, err = zap.NewDevelopment()
	} else {
		logger, err = zap.NewProduction()
	}
	if err != nil {
		log.Fatalf("failed to create logger: %v", err)
	}
	defer logger.Sync()

	// --- Graceful Shutdown ---
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// --- NATS Publisher ---
	pub, err := egress.NewNATSPublisher(egress.NATSConfig{
		URL:   cfg.NATS.URL,
		Token: cfg.NATS.Token,
	}, logger)
	if err != nil {
		logger.Fatal("failed to connect to NATS", zap.Error(err))
	}
	defer pub.Close()

	// --- Build MQTT topics and transformers from converters ---
	var topics []mqtt.TopicConfig
	transformers := make(map[string]*transform.Transformer)

	for _, conv := range cfg.Converters {
		if conv.Source.Adapter != "mqtt" {
			logger.Warn("unsupported adapter, skipping converter",
				zap.String("converter", conv.Name),
				zap.String("adapter", conv.Source.Adapter))
			continue
		}

		topics = append(topics, mqtt.TopicConfig{
			Topic: conv.Source.Topic,
			QoS:   conv.Source.QoS,
		})

		def := transform.ConverterDef{
			Name:    conv.Name,
			Mapping: conv.Mapping,
			Target:  conv.Target,
		}
		transformers[conv.Source.Topic] = transform.NewTransformer(def, logger)
	}

	if len(topics) == 0 {
		logger.Fatal("no MQTT converters configured")
	}

	// --- MQTT Adapter ---
	bufSize := cfg.Adapters.MQTT.BufferSize
	if bufSize <= 0 {
		bufSize = 1000
	}

	mqttAdapter := mqtt.New(mqtt.Config{
		Broker:     cfg.Adapters.MQTT.Broker,
		ClientID:   cfg.Adapters.MQTT.ClientID,
		Username:   cfg.Adapters.MQTT.Auth.Username,
		Password:   cfg.Adapters.MQTT.Auth.Password,
		Topics:     topics,
		BufferSize: bufSize,
	}, logger)

	if err := mqttAdapter.Start(ctx); err != nil {
		logger.Fatal("failed to start MQTT adapter", zap.Error(err))
	}
	defer mqttAdapter.Stop(ctx)

	logger.Info("data-converter started",
		zap.String("config", configPath),
		zap.Int("converters", len(transformers)),
	)

	// --- Core Loop ---
	coreLoop(ctx, mqttAdapter, pub, logger, func(msg adapter.RawMessage) (*telemetry.TelemetryMessage, string, error) {
		t := findTransformer(transformers, msg.Topic)
		if t == nil {
			return nil, "", fmt.Errorf("no transformer matched topic %q", msg.Topic)
		}
		result, err := t.Transform(msg.Topic, msg.Payload)
		if err != nil {
			return nil, "", err
		}
		return result.Message, result.Subject, nil
	})
}

// findTransformer finds the matching transformer for a given topic.
// It checks for exact match first, then tries MQTT wildcard matching.
func findTransformer(transformers map[string]*transform.Transformer, topic string) *transform.Transformer {
	if t, ok := transformers[topic]; ok {
		return t
	}
	for pattern, t := range transformers {
		if matchMQTTTopic(pattern, topic) {
			return t
		}
	}
	return nil
}

// matchMQTTTopic checks if a topic matches an MQTT wildcard pattern.
func matchMQTTTopic(pattern, topic string) bool {
	patternParts := strings.Split(pattern, "/")
	topicParts := strings.Split(topic, "/")

	for i, pp := range patternParts {
		if pp == "#" {
			return true
		}
		if i >= len(topicParts) {
			return false
		}
		if pp != "+" && pp != topicParts[i] {
			return false
		}
	}
	return len(patternParts) == len(topicParts)
}

// transformFunc is the signature for a message transformation function.
type transformFunc func(msg adapter.RawMessage) (*telemetry.TelemetryMessage, string, error)

// coreLoop reads messages from the adapter, transforms them, and publishes to NATS.
func coreLoop(ctx context.Context, a adapter.IngressAdapter, pub egress.Publisher, logger *zap.Logger, transform transformFunc) {
	for {
		select {
		case <-ctx.Done():
			logger.Info("shutting down")
			return
		case msg, ok := <-a.Messages():
			if !ok {
				logger.Info("message channel closed")
				return
			}

			tm, subject, err := transform(msg)
			if err != nil {
				logger.Warn("transform failed",
					zap.String("topic", msg.Topic),
					zap.Error(err),
				)
				continue
			}

			logger.Info("message converted",
				zap.String("topic", msg.Topic),
				zap.String("subject", subject),
				zap.String("device_id", tm.DeviceId),
				zap.Int("sensors", len(tm.SensorData)),
			)

			data, err := proto.Marshal(tm)
			if err != nil {
				logger.Error("protobuf marshal failed", zap.Error(err))
				continue
			}

			if err := pub.Publish(ctx, subject, data); err != nil {
				logger.Error("publish failed",
					zap.String("subject", subject),
					zap.Error(err),
				)
			}
		}
	}
}
