package main

import (
	"context"
	"fmt"
	"regexp"
	"strings"
	"time"

	"cloud.google.com/go/bigtable"
	"go.uber.org/zap"
)

// The implementation of this callback type streams the gRPC response
type queryCallback func(row bigtable.Row) bool

type QueryOptions struct {
	VehicleId string
	StartTime time.Time
	EndTime   time.Time
	Columns   []string
}

// Main query function for forward scanning over a specific time range.
func (s *Server) queryTelemetry(
	ctx context.Context,
	tbl *bigtable.Table,
	opts QueryOptions,
	callback queryCallback,
) error {
	// 1. Build the row key range for an efficient scan.
	rowRange := s.buildRowRange(opts.VehicleId, opts.StartTime, opts.EndTime)

	// 2. Build the filter for the specified columns.
	columnFilter := s.buildColumnFilter(opts.Columns)

	// 3. Execute the scan using the row range and the final combined filter.
	var err error

	err = tbl.ReadRows(
		ctx,
		rowRange,
		callback,
		bigtable.RowFilter(columnFilter),
	)
	if err != nil {
		return fmt.Errorf("failed during ReadRows: %w", err)
	}

	return nil
}

func (s *Server) queryLatestTelemetry(
	ctx context.Context,
	tbl *bigtable.Table,
	opts QueryOptions,
	callback queryCallback,
) error {
	rowRange := s.buildRowRange(opts.VehicleId, opts.StartTime, opts.EndTime)

	for _, data_type := range opts.Columns {
		columnFilter := s.buildSingleColumnFilter(data_type)

		err := tbl.ReadRows(
			ctx,
			rowRange,
			callback,
			bigtable.RowFilter(columnFilter),
			bigtable.LimitRows(1),  // Only the latest entry is queried
			bigtable.ReverseScan(), // Starting from the latest entry
		)
		if err != nil {
			return fmt.Errorf("failed during ReadRows: %w", err)
		}
	}

	return nil
}

// Constructs a Bigtable row range to scan for a specific VIN within a given time window.
func (s *Server) buildRowRange(vin string, startTime, endTime time.Time) bigtable.RowRange {
	startKey := fmt.Sprintf("%s#%s", vin, startTime.UTC().Format(TimestampFormat))
	endKey := fmt.Sprintf("%s#%s", vin, endTime.UTC().Format(TimestampFormat))

	s.log.Debug(
		"Building Key Range ",
		zap.String("from ", startKey),
		zap.String("to ", endKey),
	)

	return bigtable.NewRange(startKey, endKey)
}

// Creates a Bigtable filter to retrieve only the one specified column.
func (s *Server) buildSingleColumnFilter(data_type string) bigtable.Filter {
	parts := strings.Split(data_type, ":")
	family, qualifier := parts[0], parts[1]

	qualifierRegex := fmt.Sprintf("^(%s)$", qualifier)
	return bigtable.ChainFilters(
		bigtable.FamilyFilter(family),
		bigtable.ColumnFilter(qualifierRegex),
	)
}

// Creates a Bigtable filter to retrieve only the specified columns.
func (s *Server) buildColumnFilter(dataTypes []string) bigtable.Filter {
	// Group the requested qualifiers by their column family.
	familyToQualifiers := make(map[string][]string)

	for _, datatype := range dataTypes {
		parts := strings.SplitN(datatype, ":", 2)
		if len(parts) == 2 {
			family, qualifier := parts[0], parts[1]
			familyToQualifiers[family] = append(familyToQualifiers[family], qualifier)
		}
	}

	// If no valid "family:qualifier" strings were found, return a filter that matches nothing.
	if len(familyToQualifiers) == 0 {
		return bigtable.BlockAllFilter()
	}

	// For each family, create a specific "AND" filter for its qualifiers.
	var familyFilters []bigtable.Filter
	for family, qualifiers := range familyToQualifiers {
		// Escape the qualifiers to be safe for regex.
		var escaped []string
		for _, q := range qualifiers {
			escaped = append(escaped, regexp.QuoteMeta(q))
		}
		// Build a regex like "^(qualifier_1|qualifier_2|...)$"
		qualifierRegex := fmt.Sprintf("^(%s)$", strings.Join(escaped, "|"))

		s.log.Debug(
			"Building Qualifier Filter Regex ",
			zap.String("regex ", qualifierRegex),
			zap.String("family ", family),
		)

		// InterleaveFilters acts as an "AND" for the family and column filter.
		filter := bigtable.ChainFilters(
			bigtable.FamilyFilter(family),
			bigtable.ColumnFilter(qualifierRegex),
		)
		familyFilters = append(familyFilters, filter)
	}

	// If there's only one family, we don't need to interleave.
	if len(familyFilters) == 1 {
		return familyFilters[0]
	}

	// InterleaveFilters acts as an "OR" for the different family filters.
	return bigtable.InterleaveFilters(familyFilters...)
}

func parseTimestampFromRowKey(key string) (time.Time, bool) {
	// Find the last '#' character in the RowKey after which comes the timestamp.
	lastHashIndex := strings.LastIndex(key, "#")
	if lastHashIndex == -1 || lastHashIndex == len(key)-1 {
		return time.Time{}, false
	}

	// Extract the timestamp part of the string.
	timestampStr := key[lastHashIndex+1:]

	// Parse the string using the global format.
	ts, err := time.Parse(TimestampFormat, timestampStr)
	if err != nil {
		// The string after the '#' was not a valid timestamp.
		return time.Time{}, false
	}

	return ts, true
}
