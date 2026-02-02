package main

import (
	"context"
	dataapiv1 "data-api/api/gen/dataapi/v1"
	"log"
	"net"
	"os"
	"time"

	"cloud.google.com/go/bigtable"
	"go.uber.org/zap"
	"google.golang.org/grpc"
)

func main() {
	// --- Create logger ---
	var logger *zap.Logger
	var err error
	if os.Getenv("LOG_LEVEL") == "debug" {
		// Development logger is verbose and includes debug messages.
		logger, err = zap.NewDevelopment()
	} else {
		// Production logger is structured and defaults to the info level.
		logger, err = zap.NewProduction()
	}
	if err != nil {
		log.Fatalf("failed to create logger: %v", err)
	}
	defer logger.Sync()

	// --- Configuration ---
	grpcAddr := os.Getenv("GRPC_ADDR")
	gcpProject := os.Getenv("GCP_PROJECT")
	btInstance := os.Getenv("BT_INSTANCE")
	btTable := os.Getenv("BT_TABLE")

	// --- Bigtable Connection
	ctx := context.Background()
	btClient, err := bigtable.NewClient(ctx, gcpProject, btInstance)
	if err != nil {
		logger.Fatal("failed to create bigtable client", zap.Error(err))
	}
	defer btClient.Close()

	tbl := btClient.Open(btTable)

	// --- Server Setup ---
	lis, err := net.Listen("tcp", grpcAddr)
	if err != nil {
		logger.Fatal("failed to listen on address", zap.String("addr", grpcAddr), zap.Error(err))
	}

	grpcServer := grpc.NewServer()
	telemetryServer := NewServer(logger, tbl, Options{
		MaxLookback: 365 * 24 * time.Hour,
	})

	dataapiv1.RegisterTelemetryDataAPIServer(grpcServer, telemetryServer)

	logger.Info("gRPC server listening", zap.String("addr", grpcAddr))
	if err := grpcServer.Serve(lis); err != nil {
		logger.Fatal("gRPC server failed to serve", zap.Error(err))
	}
}
