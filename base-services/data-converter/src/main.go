package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"

	telemetry "data-converter/api/gen/telemetry"
	"data-converter/src/egress"
	"data-converter/src/ingress"
	_ "data-converter/src/ingress/mqtt" // register MQTT adapter
	"data-converter/src/transform"

	"go.uber.org/zap"
	"google.golang.org/protobuf/proto"
)

// converterEntry pairs a transformer with the topic matcher of its adapter.
type converterEntry struct {
	transformer *transform.Transformer
	matcher     ingress.TopicMatcher
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
		URL:   cfg.NATS.URL,
		Token: cfg.NATS.Token,
	}, logger)
	if err != nil {
		logger.Fatal("failed to connect to NATS", zap.Error(err))
	}
	defer pub.Close()

	// --- Build adapters and transformers from converters ---
	// Group converter sources by adapter type
	adapterSources := make(map[string][]ingress.ConverterSource)
	converters := make(map[string]converterEntry)

	for _, conv := range cfg.Converters {
		adapterSources[conv.Source.Adapter] = append(adapterSources[conv.Source.Adapter], ingress.ConverterSource{
			Topic: conv.Source.Topic,
			QoS:   conv.Source.QoS,
		})

		def := transform.ConverterDef{
			Name:    conv.Name,
			Mapping: conv.Mapping,
			Target:  conv.Target,
		}
		converters[conv.Source.Topic] = converterEntry{
			transformer: transform.NewTransformer(def, logger),
			matcher:     ingress.GetTopicMatcher(conv.Source.Adapter),
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
	// Merge all adapter channels into the same loop
	transformFn := func(msg ingress.RawMessage) (*telemetry.TelemetryMessage, string, error) {
		t := findTransformer(converters, msg.Topic)
		if t == nil {
			return nil, "", fmt.Errorf("no transformer matched topic %q", msg.Topic)
		}
		result, err := t.Transform(msg.Topic, msg.Payload)
		if err != nil {
			return nil, "", err
		}
		return result.Message, result.Subject, nil
	}

	if len(adapters) == 1 {
		coreLoop(ctx, adapters[0], pub, logger, transformFn)
	} else {
		// Fan-in: merge multiple adapter channels
		merged := fanIn(ctx, adapters)
		coreLoopChan(ctx, merged, pub, logger, transformFn)
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

// findTransformer finds the matching transformer for a given topic.
// It checks for exact match first, then uses each converter's protocol-specific matcher.
func findTransformer(converters map[string]converterEntry, topic string) *transform.Transformer {
	if entry, ok := converters[topic]; ok {
		return entry.transformer
	}
	for pattern, entry := range converters {
		if entry.matcher(pattern, topic) {
			return entry.transformer
		}
	}
	return nil
}

// transformFunc is the signature for a message transformation function.
type transformFunc func(msg ingress.RawMessage) (*telemetry.TelemetryMessage, string, error)

// coreLoop reads messages from a single adapter and publishes to NATS.
func coreLoop(ctx context.Context, a ingress.Adapter, pub egress.Publisher, logger *zap.Logger, transform transformFunc) {
	coreLoopChan(ctx, a.Messages(), pub, logger, transform)
}

// coreLoopChan reads messages from a channel and publishes to NATS.
func coreLoopChan(ctx context.Context, msgs <-chan ingress.RawMessage, pub egress.Publisher, logger *zap.Logger, transform transformFunc) {
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
