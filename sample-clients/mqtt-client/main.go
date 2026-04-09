package main

import (
	"flag"
	"fmt"
	"log"
	"math/rand/v2"
	"os"
	"os/signal"
	"syscall"
	"time"

	mqtt "github.com/eclipse/paho.mqtt.golang"
)

const Topic = "telemetry/mqttDevice001/sensors/temp"

func main() {
	interval := flag.Duration("interval", 5*time.Second, "Time interval for sending telemetry messages")
	flag.Parse()

	fmt.Println("mqtt-client starting")
	fmt.Printf("Interval: %v\n", *interval)

	client := connect()

	ticker := time.NewTicker(*interval)
	defer ticker.Stop()

	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	fmt.Printf("publishing every %v — press Ctrl+C to stop\n", *interval)

	publishMessage(client)
	for {
		select {
		case <-ticker.C:
			publishMessage(client)
		case <-sigChan:
			client.Disconnect(1000)
			fmt.Println("mqtt-client stopped")
			return
		}
	}
}

func connect() mqtt.Client {
	opts := mqtt.NewClientOptions().
		AddBroker("tcp://localhost:1883").
		SetClientID("sample-mqtt-client")

	if user := os.Getenv("MQTT_USERNAME"); user != "" {
		opts.SetUsername(user)
		opts.SetPassword(os.Getenv("MQTT_PASSWORD"))
	}

	client := mqtt.NewClient(opts)
	token := client.Connect()
	token.WaitTimeout(10 * time.Second)
	if err := token.Error(); err != nil {
		log.Fatalf("connection failed: %v", err)
	}
	fmt.Printf("connected to broker: %v\n", client.IsConnected())
	return client
}

func publishMessage(client mqtt.Client) {
	jsonPayload := fmt.Sprintf(`{"name": "temperature", "value": "%v"}`, randomTemp())
	token := client.Publish(Topic, 1, false, jsonPayload)
	token.WaitTimeout(10 * time.Second)
	if err := token.Error(); err != nil {
		log.Fatalf("publish failed: %v", err)
	}
	fmt.Println("published to topic: ", Topic, ": ", jsonPayload)
}

func randomTemp() string {
	const minTemp = 15.0
	const maxTemp = 45.0
	return fmt.Sprintf("%.1f", minTemp+rand.Float64()*(maxTemp-minTemp))
}
