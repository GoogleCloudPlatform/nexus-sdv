package main

import (
	dataapiv1 "data-api/api/gen/dataapi/v1"
	"strings"
	"time"

	"cloud.google.com/go/bigtable"
	"go.uber.org/zap"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// Holds default settings and options for the Server.
type Options struct {
	MaxLookback time.Duration
}

// Server is the implementation of the TelemetryDataAPIServer.
type Server struct {
	dataapiv1.UnimplementedTelemetryDataAPIServer
	log *zap.Logger
	tbl *bigtable.Table
	opt Options
}

func NewServer(log *zap.Logger, tbl *bigtable.Table, opt Options) *Server {
	log.Info("Server started.")
	log.Debug("Server server started in Debug mode.")
	return &Server{log: log, tbl: tbl, opt: opt}
}

// GetTelemetryData is the main RPC method.
func (s *Server) GetTelemetryData(req *dataapiv1.GetTelemetryDataRequest, stream dataapiv1.TelemetryDataAPI_GetTelemetryDataServer) error {
	ctx := stream.Context()
	s.log.Debug("Received GetTelemetryData request",
		zap.String("vehicle_id", req.VehicleId),
		zap.String("data_types", strings.Join(req.GetDataTypes(), "")),
		zap.Any("time_selector", req.TimeSelector),
	)

	// 1. Validate request and calculate effective time window
	eff, err := computeEffectiveWindow(req, s.opt.MaxLookback)
	if err != nil {
		return status.Error(codes.InvalidArgument, err.Error())
	}

	// 2. Set the query method based on the time selector
	queryMethod := s.queryTelemetry
	if _, isLatest := req.TimeSelector.(*dataapiv1.GetTelemetryDataRequest_Latest); isLatest {
		queryMethod = s.queryLatestTelemetry
	}

	// 3. Set the other query options
	queryOptions := QueryOptions{
		VehicleId: req.VehicleId,
		StartTime: eff.Start,
		EndTime:   eff.End,
		Columns:   req.DataTypes,
	}

	// 4. Execute the selected query method with a callback that streams all results to the client
	err = queryMethod(
		ctx,
		s.tbl,
		queryOptions,
		func(r bigtable.Row) bool {
			point, ok := s.parseRowToTelemetryPoint(r)
			if !ok {
				return true // Skip malformed row and continue
			}

			if err := stream.Send(point); err != nil {
				return false // Client likely disconnected. Stop the scan.
			}
			return true // Continue scanning.
		},
	)
	if err != nil {
		// Log the error from the query method itself.
		s.log.Error("Query execution failed", zap.Error(err))
		return status.Error(codes.Internal, "failed to execute query")
	}

	return nil
}

// Parses Rows from bigtable into TelemetryPoints that are ready to be streamed to the client.
func (s *Server) parseRowToTelemetryPoint(r bigtable.Row) (*dataapiv1.TelemetryPoint, bool) {
	ts, ok := parseTimestampFromRowKey(r.Key())
	if !ok {
		s.log.Warn("Skipping malformed row key", zap.String("key", r.Key()))
		return nil, false
	}

	point := &dataapiv1.TelemetryPoint{
		Timestamp: timestamppb.New(ts),
		Values:    make(map[string][]byte),
	}

	// Loop over all families present in the row data.
	for _, items := range r {
		for _, item := range items {
			// item.Column is "family:qualifier". We use this full name as the key.
			point.Values[item.Column] = item.Value
		}
	}

	if len(point.Values) == 0 {
		return nil, false
	}
	return point, true
}
