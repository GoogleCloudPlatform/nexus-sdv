package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"

	telemetry "data-converter/api/gen/telemetry"
	"data-converter/src/convert"
	"data-converter/src/egress"
	"data-converter/src/ingress"
	_ "data-converter/src/ingress/mqtt" // register MQTT adapter

	"go.uber.org/zap"
	"google.golang.org/protobuf/proto"
)

// converterEntry pairs a converter with the pattern matcher of its adapter.
type converterEntry struct {
	converter *convert.Converter
	matcher   ingress.TopicMatcher
}

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
		URL:      cfg.NATS.URL,
		Token:    cfg.NATS.Token,
		User:     cfg.NATS.User,
		Password: cfg.NATS.Password,
	}, logger)
	if err != nil {
		logger.Fatal("failed to connect to NATS", zap.Error(err))
	}
	defer pub.Close()

	// --- Build adapters and converters ---
	adapterSources := make(map[string][]ingress.ConverterSource)
	converters := make(map[string]converterEntry)

	for _, conv := range cfg.Converters {
		adapterSources[conv.Source.Adapter] = append(adapterSources[conv.Source.Adapter], ingress.ConverterSource{
			Topic: conv.Source.Topic,
			QoS:   conv.Source.QoS,
		})

		def := convert.ConverterDef{
			Name:    conv.Name,
			Mapping: conv.Mapping,
			Target:  conv.Target,
		}
		converters[conv.Source.Topic] = converterEntry{
			converter: convert.NewConverter(def, logger),
			matcher:   ingress.GetTopicMatcher(conv.Source.Adapter),
		}
	}

	// Create and start one adapter per type
	var adapters []ingress.Adapter
	for adapterName, sources := range adapterSources {
		adapterCfg, ok := cfg.Adapters[adapterName]
		if !ok {
			logger.Fatal("adapter referenced in converter but not configured",
				zap.String("adapter", adapterName))
		}

		a, err := ingress.NewAdapter(adapterName, adapterCfg, sources, logger)
		if err != nil {
			logger.Fatal("failed to create adapter",
				zap.String("adapter", adapterName),
				zap.Error(err))
		}

		if err := a.Start(ctx); err != nil {
			logger.Fatal("failed to start adapter",
				zap.String("adapter", adapterName),
				zap.Error(err))
		}
		defer a.Stop(ctx)

		adapters = append(adapters, a)
	}

	if len(adapters) == 0 {
		logger.Fatal("no adapters configured")
	}

	logger.Info("data-converter started",
		zap.String("config", configPath),
		zap.Int("converters", len(converters)),
		zap.Int("adapters", len(adapters)),
	)

	// --- Core Loop ---
	convertFn := func(msg ingress.RawMessage) (*telemetry.TelemetryMessage, string, error) {
		c := findConverter(converters, msg.Topic)
		if c == nil {
			return nil, "", fmt.Errorf("no converter matched topic %q", msg.Topic)
		}
		result, err := c.Convert(msg.Topic, msg.Payload)
		if err != nil {
			return nil, "", err
		}
		return result.Message, result.Subject, nil
	}

	if len(adapters) == 1 {
		coreLoop(ctx, adapters[0], pub, logger, convertFn)
	} else {
		merged := fanIn(ctx, adapters)
		coreLoopChan(ctx, merged, pub, logger, convertFn)
	}
}

// fanIn merges message channels from multiple adapters into one.
func fanIn(ctx context.Context, adapters []ingress.Adapter) <-chan ingress.RawMessage {
	merged := make(chan ingress.RawMessage, 1000)
	for _, a := range adapters {
		go func(ch <-chan ingress.RawMessage) {
			for {
				select {
				case <-ctx.Done():
					return
				case msg, ok := <-ch:
					if !ok {
						return
					}
					merged <- msg
				}
			}
		}(a.Messages())
	}
	return merged
}

// findConverter finds the matching converter for a given topic.
// It checks for exact match first, then uses each converter's protocol-specific matcher.
func findConverter(converters map[string]converterEntry, topic string) *convert.Converter {
	if entry, ok := converters[topic]; ok {
		return entry.converter
	}
	for pattern, entry := range converters {
		if entry.matcher(pattern, topic) {
			return entry.converter
		}
	}
	return nil
}

// convertFunc is the signature for a message conversion function.
type convertFunc func(msg ingress.RawMessage) (*telemetry.TelemetryMessage, string, error)

// coreLoop reads messages from a single adapter and publishes to NATS.
func coreLoop(ctx context.Context, a ingress.Adapter, pub egress.Publisher, logger *zap.Logger, convert convertFunc) {
	coreLoopChan(ctx, a.Messages(), pub, logger, convert)
}

// coreLoopChan reads messages from a channel and publishes to NATS.
func coreLoopChan(ctx context.Context, msgs <-chan ingress.RawMessage, pub egress.Publisher, logger *zap.Logger, convert convertFunc) {
	for {
		select {
		case <-ctx.Done():
			logger.Info("shutting down")
			return
		case msg, ok := <-msgs:
			if !ok {
				logger.Info("message channel closed")
				return
			}

			telemetryMessage, subject, err := convert(msg)
			if err != nil {
				logger.Warn("conversion failed",
					zap.String("topic", msg.Topic),
					zap.Error(err),
				)
				continue
			}

			logger.Info("message converted",
				zap.String("topic", msg.Topic),
				zap.String("subject", subject),
				zap.String("device_id", telemetryMessage.DeviceId),
				zap.Int("sensors", len(telemetryMessage.SensorData)),
			)

			data, err := proto.Marshal(telemetryMessage)
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
