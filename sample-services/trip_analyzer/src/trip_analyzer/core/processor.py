import queue
from asyncio import CancelledError
from datetime import datetime, timedelta

from grpclib.exceptions import StreamTerminatedError

from trip_analyzer.client.generated.dataapi.v1 import TelemetryDataApiStub, GetTelemetryDataRequest
from trip_analyzer.config.config import settings
from trip_analyzer.config.logging import logger
from trip_analyzer.client.nats_client import NatsConnector
from trip_analyzer.core.scorer import score_trip
from trip_analyzer.model.scoring_message import ScoringMessage


class Processor:
    def __init__(self, connector: TelemetryDataApiStub, nats: NatsConnector):
        self._dataApi: TelemetryDataApiStub = connector
        self._nats: NatsConnector = nats

    async def scoreDrivingStyle(self, id: str):
        end = datetime.now()
        start = end - timedelta(seconds=settings.data_api_timeout)
        request = GetTelemetryDataRequest(
            vehicle_id=id, data_types=["dynamic:VELOCITY"],
            # time_range=TimeRange(start=start, end=end)
            last_duration=timedelta(seconds=settings.data_poll_interval)
        )

        input_list = []
        try:
            async for point in self._dataApi.get_telemetry_data(request):
                temp_bytes = point.values.get("dynamic:VELOCITY")
                velocity_m_s = float(temp_bytes.decode('utf-8').strip('"'))
                velocity_km_h = velocity_m_s * 3.6
                formatted_time = point.timestamp.time().strftime("%H:%M:%S")
                logger.debug("Received data", vehicle_id=id, timestamp=formatted_time, data=velocity_km_h)
                # CHECK: Only append if the list is empty OR the timestamp is different
                if not input_list or formatted_time != input_list[-1][0]:
                    input_list.append((formatted_time, velocity_km_h))
                else:
                    logger.debug("Skipping duplicate timestamp", time_stamp=formatted_time)

        except Exception as e:
            logger.error("An error occurred during scoring", error=repr(e))

        if len(input_list) < 5:
            logger.debug("Not enough Data for scoring",
                        vehicle_id=id, input_amount=len(input_list))
        else:
            logger.debug("Calculating batch: ", batch=input_list)
            result = score_trip(input_list)
            logger.info("Score calculated for Vehicle", vehicle_id=id, score=result.score,
                        suggestions=result.suggestions)
            if not self._nats.is_connected:
                self._nats.connect()
            await self._nats.publish_message(subject=f"scoring.{id}",
                                             message=ScoringMessage(vehicle_id=id, score=str(result.score),
                                                                    suggestions=list(result.suggestions)))
            input_list.clear()
