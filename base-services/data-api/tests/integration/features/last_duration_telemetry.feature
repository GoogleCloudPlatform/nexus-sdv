Feature: Telemetry Data API
  As a data consuming service
  I want to query vehicle telemetry
  So that I can provide applications with data

  Background:
    Given the telemetry bigtable is available

  Scenario: Get telemetry data for the last duration
    Given vehicle "VIN123456789ABCDEF" has the following telemetry data:
      | timestamp                      | data_type     | value |
      | 2024-01-15T09:00:00.000000000Z | dynamic:speed |  60.0 |
      | 2024-01-15T09:30:00.000000000Z | dynamic:speed |  65.0 |
      | 2024-01-15T10:00:00.000000000Z | dynamic:speed |  70.0 |
      | 2024-01-15T10:30:00.000000000Z | dynamic:speed |  75.0 |
    When I request telemetry data for vehicle "VIN123456789ABCDEF" for the last "1h" (since testing time) with data types:
      | data_type     |
      | dynamic:speed |
    Then the resulting telemetry should be:
      | timestamp                      | data_type     | value |
      | 2024-01-15T10:00:00.000000000Z | dynamic:speed |  70.0 |
      | 2024-01-15T10:30:00.000000000Z | dynamic:speed |  75.0 |
