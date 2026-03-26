package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	telemetry "data-converter/api/gen/telemetry"
	"data-converter/src/adapter/mqtt"
	"data-converter/src/egress"

	"github.com/google/uuid"
	"go.uber.org/zap"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"
)

func main() {
	// --- Logger ---
	var logger *zap.Logger
	var err error
	if os.Getenv("LOG_LEVEL") == "debug" {
		logger, err = zap.NewDevelopment()
	} else {
		logger, err = zap.NewProduction()
	}
	if err != nil {
		log.Fatalf("failed to create logger: %v", err)
	}
	defer logger.Sync()

	// --- Configuration (env vars for Phase 1) ---
	mqttBroker := envOrDefault("MQTT_BROKER", "tcp://localhost:1883")
	mqttClientID := envOrDefault("MQTT_CLIENT_ID", "data-converter")
	mqttTopic := envOrDefault("MQTT_TOPIC", "test/+/telemetry")
	mqttUser := os.Getenv("MQTT_USER")
	mqttPass := os.Getenv("MQTT_PASS")
	natsURL := envOrDefault("NATS_URL", "nats://localhost:4222")
	natsToken := os.Getenv("NATS_TOKEN")

	// --- Graceful Shutdown ---
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	// --- MQTT Adapter ---
	mqttAdapter := mqtt.New(mqtt.Config{
		Broker:   mqttBroker,
		ClientID: mqttClientID,
		Username: mqttUser,
		Password: mqttPass,
		Topics: []mqtt.TopicConfig{
			{Topic: mqttTopic, QoS: 1},
		},
		BufferSize: 1000,
	}, logger)

	if err := mqttAdapter.Start(ctx); err != nil {
		logger.Fatal("failed to start MQTT adapter", zap.Error(err))
	}
	defer mqttAdapter.Stop(ctx)

	// --- NATS Publisher ---
	pub, err := egress.NewNATSPublisher(egress.NATSConfig{
		URL:   natsURL,
		Token: natsToken,
	}, logger)
	if err != nil {
		logger.Fatal("failed to connect to NATS", zap.Error(err))
	}
	defer pub.Close()

	logger.Info("data-converter started",
		zap.String("mqtt_broker", mqttBroker),
		zap.String("mqtt_topic", mqttTopic),
		zap.String("nats_url", natsURL),
	)

	// --- Core Loop ---
	for {
		select {
		case <-ctx.Done():
			logger.Info("shutting down")
			return
		case msg, ok := <-mqttAdapter.Messages():
			if !ok {
				logger.Info("message channel closed")
				return
			}

			tm, subject, err := transformHardcoded(msg.Topic, msg.Payload)
			if err != nil {
				logger.Warn("transform failed",
					zap.String("topic", msg.Topic),
					zap.Error(err),
				)
				continue
			}

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

// transformHardcoded converts a JSON payload from an MQTT message into a TelemetryMessage.
// Expected topic format: test/{device_id}/telemetry
// Expected JSON: {"sensor": "speed", "value": "120.5"}
func transformHardcoded(topic string, payload []byte) (*telemetry.TelemetryMessage, string, error) {
	segments := strings.Split(topic, "/")
	if len(segments) < 2 {
		return nil, "", fmt.Errorf("topic has too few segments: %s", topic)
	}
	deviceID := segments[1]

	var data map[string]interface{}
	if err := json.Unmarshal(payload, &data); err != nil {
		return nil, "", fmt.Errorf("json unmarshal: %w", err)
	}

	sensorName, _ := data["sensor"].(string)
	sensorValue, _ := data["value"].(string)
	if sensorName == "" {
		return nil, "", fmt.Errorf("missing 'sensor' field in payload")
	}

	msg := &telemetry.TelemetryMessage{
		MessageId:     uuid.NewString(),
		SchemaVersion: 1,
		DeviceId:      deviceID,
		SensorData: []*telemetry.SensorReading{
			{
				Timestamp: timestamppb.New(time.Now()),
				Value:     sensorValue,
				DataType:  telemetry.DataType_DYNAMIC,
				Sensor:    sensorName,
			},
		},
	}

	subject := fmt.Sprintf("telemetry.%s.%s", deviceID, sensorName)
	return msg, subject, nil
}

func envOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
