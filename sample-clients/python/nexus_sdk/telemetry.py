from uuid import uuid4
from proto import telemetry_pb2
from datetime import datetime, timezone
from dataclasses import dataclass
from proto.telemetry_pb2 import DataType

@dataclass
class SensorReading:
    sensor: str
    value: str
    data_type: telemetry_pb2.DataType
def telemetry_message(vin: str, readings: list[SensorReading]) -> telemetry_pb2.TelemetryMessage:
    timestamp=datetime.now(timezone.utc)

    return telemetry_pb2.TelemetryMessage(
        message_id=str(uuid4()),
        schema_version=1,
        device_id=vin,

        sensor_data=[
            telemetry_pb2.SensorReading(
                timestamp=timestamp,
                sensor=reading.sensor,
                value=reading.value,
                data_type=reading.data_type,
            )
            for reading in readings
        ]
    )