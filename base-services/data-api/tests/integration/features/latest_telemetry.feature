Feature: Telemetry Data API
  As a data consuming service
  I want to query vehicle telemetry
  So that I can provide applications with data

  Background:
    Given the telemetry bigtable is available

  Scenario: Get latest telemetry data for multiple data points
    Given vehicle "VIN123456789ABCDEF" has the following telemetry data:
      | timestamp                      | data_type            | value     |
      | 2024-01-15T10:30:00.000000000Z | dynamic:location.lat |   52.5200 |
      | 2024-01-15T10:31:00.000000000Z | dynamic:location.lon |   13.4050 |
      | 2024-01-15T10:32:00.000000000Z | static:make          | Ford F150 |
      | 2024-01-15T10:40:00.000000000Z | dynamic:location.lat |   52.5210 |
      | 2024-01-15T10:41:00.000000000Z | dynamic:location.lon |   13.4060 |
    When I request the latest telemetry data for vehicle "VIN123456789ABCDEF" with data types:
      | data_type            |
      | dynamic:location.lat |
      | dynamic:location.lon |
      | static:make          |
    Then the resulting telemetry should be:
      | timestamp                      | data_type            | value     |
      | 2024-01-15T10:40:00.000000000Z | dynamic:location.lat |   52.5210 |
      | 2024-01-15T10:41:00.000000000Z | dynamic:location.lon |   13.4060 |
      | 2024-01-15T10:32:00.000000000Z | static:make          | Ford F150 |

  Scenario: Get latest telemetry data for multiple data points with the same timestamps
    Given vehicle "VIN123456789ABCDEF" has the following telemetry data:
      | timestamp                      | data_type            | value     |
      | 2024-01-15T10:30:00.000000000Z | dynamic:location.lat |   52.5200 |
      | 2024-01-15T10:30:00.000000000Z | dynamic:location.lon |   13.4050 |
      | 2024-01-15T10:30:00.000000000Z | static:make          | Ford F150 |
      | 2024-01-15T10:35:00.000000000Z | dynamic:location.lat |   52.5210 |
      | 2024-01-15T10:35:00.000000000Z | dynamic:location.lon |   13.4060 |
    When I request the latest telemetry data for vehicle "VIN123456789ABCDEF" with data types:
      | data_type            |
      | static:make          |
      | dynamic:location.lat |
      | dynamic:location.lon |
    Then the resulting telemetry should be:
      | timestamp                      | data_type            | value     |
      | 2024-01-15T10:30:00.000000000Z | static:make          | Ford F150 |
      | 2024-01-15T10:35:00.000000000Z | dynamic:location.lat |   52.5210 |
      | 2024-01-15T10:35:00.000000000Z | dynamic:location.lon |   13.4060 |

  Scenario: Get latest telemetry data for a single data type
    Given vehicle "VIN123456789ABCDEF" has the following telemetry data:
      | timestamp                      | data_type            | value   |
      | 2024-01-15T10:30:00.000000000Z | dynamic:location.lat | 52.5200 |
      | 2024-01-15T10:31:00.000000000Z | dynamic:location.lon | 13.4050 |
      | 2024-01-15T10:32:00.000000000Z | dynamic:speed        |    65.5 |
      | 2024-01-15T10:40:00.000000000Z | dynamic:location.lat | 52.5210 |
      | 2024-01-15T10:41:00.000000000Z | dynamic:location.lon | 13.4060 |
      | 2024-01-15T10:42:00.000000000Z | dynamic:speed        |    70.2 |
    When I request the latest telemetry data for vehicle "VIN123456789ABCDEF" with data types:
      | data_type     |
      | dynamic:speed |
    Then the resulting telemetry should be:
      | timestamp                      | data_type     | value |
      | 2024-01-15T10:42:00.000000000Z | dynamic:speed |  70.2 |

  Scenario: Get latest telemetry data with an empty list of data types
    Given vehicle "VIN123456789ABCDEF" has the following telemetry data:
      | timestamp                      | data_type            | value   |
      | 2024-01-15T10:30:00.000000000Z | dynamic:location.lat | 52.5200 |
      | 2024-01-15T10:31:00.000000000Z | dynamic:location.lon | 13.4050 |
    When I request the latest telemetry data for vehicle "VIN123456789ABCDEF" with data types:
      | data_type |
    Then the resulting telemetry should be:
      | data_type | value |
