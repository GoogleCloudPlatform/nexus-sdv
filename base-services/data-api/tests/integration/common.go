package integration

import "github.com/cucumber/godog"

// parseDataTableToStringSlice is a utility to extract the first column of a godog.Table
// into a slice of strings. It skips the header row.
func parseDataTableToStringSlice(table *godog.Table) []string {
	var stringSlice []string
	if table == nil || len(table.Rows) <= 1 {
		return stringSlice
	}
	for i := 1; i < len(table.Rows); i++ {
		stringSlice = append(stringSlice, table.Rows[i].Cells[0].Value)
	}
	return stringSlice
}

// parseKeyValueTable is a utility to extract a two-column godog.Table
// into a map of strings. It skips the header row.
func parseKeyValueTable(table *godog.Table) map[string]string {
	keyValueMap := make(map[string]string)
	if table == nil || len(table.Rows) <= 1 {
		return keyValueMap
	}
	for i := 1; i < len(table.Rows); i++ {
		key := table.Rows[i].Cells[0].Value
		value := table.Rows[i].Cells[1].Value
		keyValueMap[key] = value
	}
	return keyValueMap
}
