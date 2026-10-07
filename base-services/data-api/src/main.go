package main

import (
	"context"
	dataapiv1 "data-api/api/gen/dataapi/v1"
	"data-api/src/auth"
	"data-api/src/service"
	"log"
	"net"
	"os"
	"time"

	"cloud.google.com/go/bigtable"
	"go.uber.org/zap"
	"google.golang.org/grpc"
)

// defaultRealmRole is the role a caller's token must carry. It is the role the
// factory-helper already requires, so a platform has one operator credential
// rather than three.
const defaultRealmRole = "factory-operator"

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

	grpcServer := grpc.NewServer(serverOptions(logger)...)
	telemetryServer := service.NewServer(logger, tbl, service.Options{
		MaxLookback: 365 * 24 * time.Hour,
	})

	dataapiv1.RegisterTelemetryDataAPIServer(grpcServer, telemetryServer)

	logger.Info("gRPC server listening", zap.String("addr", grpcAddr))
	if err := grpcServer.Serve(lis); err != nil {
		logger.Fatal("gRPC server failed to serve", zap.Error(err))
	}
}

// serverOptions builds the server's two authentication interceptors.
//
// The Data API is cluster-internal and speaks plaintext gRPC, like the
// platform's other internal services: in-cluster callers fetch their token from
// Keycloak over plain HTTP anyway, and a port forward is already encrypted from
// the workstation to the pod. What it keeps is the token check.
//
// Authentication is mandatory. The single exception is a server pointed at a BigTable
// emulator, which is how docker-compose runs it: BIGTABLE_EMULATOR_HOST is a
// Google client-library variable that no deployed platform sets, so the
// exception cannot be switched on by accident in a cluster. There is
// deliberately no flag that disables authentication — a flag is something that
// can leak into a deployment, and an open Data API is the defect this exists to
// prevent.
func serverOptions(logger *zap.Logger) []grpc.ServerOption {
	if host := os.Getenv("BIGTABLE_EMULATOR_HOST"); host != "" {
		logger.Warn("BigTable emulator configured: serving plaintext gRPC without authentication",
			zap.String("emulator", host))
		return nil
	}

	verifier, err := auth.NewVerifierFromDiscovery(
		os.Getenv("KEYCLOAK_JWK_B64"),
		os.Getenv("KEYCLOAK_DISCOVERY_URL"),
		realmRole(),
	)
	if err != nil {
		logger.Fatal("refusing to serve without authentication", zap.Error(err))
	}

	logger.Info("serving gRPC, callers need a Keycloak token",
		zap.String("issuer_from", os.Getenv("KEYCLOAK_DISCOVERY_URL")),
		zap.String("required_role", realmRole()))

	// Both interceptors: GetTelemetryData is server-streaming, so the stream
	// interceptor is the one that actually guards the telemetry. The unary one
	// is here so a future unary RPC cannot arrive unguarded.
	return []grpc.ServerOption{
		grpc.UnaryInterceptor(verifier.UnaryInterceptor()),
		grpc.StreamInterceptor(verifier.StreamInterceptor()),
	}
}

func realmRole() string {
	if role := os.Getenv("REQUIRED_REALM_ROLE"); role != "" {
		return role
	}
	return defaultRealmRole
}
