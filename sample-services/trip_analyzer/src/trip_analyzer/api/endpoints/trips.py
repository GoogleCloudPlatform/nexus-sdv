import json
from fastapi import APIRouter, Response, Request
from starlette.responses import JSONResponse
from trip_analyzer.config.config import settings
from trip_analyzer.client.generated.dataapi.v1 import TelemetryDataApiStub, GetTelemetryDataRequest, TimeRange
from trip_analyzer.config.config import settings
from trip_analyzer.core.scorer import score_trip
from trip_analyzer.config.logging import logger
from trip_analyzer.client.DataApiConnector import DataApiConnector
from datetime import datetime, timedelta, timezone
from trip_analyzer.model.scoring_message import ScoringMessage

router = APIRouter()


@router.post(path="/{id}")
async def calculateScore(request: Request, id: str, start_time: datetime = None, end_time: datetime = None):
    logger.info("Calculate Score for: ", vehicle_id=id, start_time=start_time, end_time=end_time)
    telemetry_stub = request.app.state.data_api.get_client()
    nats_client = request.app.state.nats_client

    end_time, start_time = await normalize_timestamps(end_time, start_time)

    if not start_time or not end_time:
        logger.info("Start time or end time not set, retrieving last trip.")
        request = GetTelemetryDataRequest(
            vehicle_id=id, data_types=["dynamic:VELOCITY"],
            latest=True
        )
        last_request = await anext(telemetry_stub.get_telemetry_data(request), None)
        if not last_request:
            return JSONResponse(status_code=204, content=None)
        end_time = last_request.timestamp
        start_time = end_time - timedelta(minutes=3)

    logger.info("Requesting Data for: ", vehicle_id=id, start_time=start_time, end_time=end_time)
    request = GetTelemetryDataRequest(
        vehicle_id=id, data_types=["dynamic:VELOCITY"],
        time_range=TimeRange(start=start_time, end=end_time)
    )

    input_list = []
    try:
        async for point in telemetry_stub.get_telemetry_data(request):
            temp_bytes = point.values.get("dynamic:VELOCITY")
            velocity_m_s = float(temp_bytes.decode('utf-8').strip('"'))
            velocity_km_h = velocity_m_s * 3.6
            formatted_time = point.timestamp.time().strftime("%H:%M:%S")
            logger.info("Received data", vehicle_id=id, time_stamp=formatted_time, data=velocity_km_h)
            # CHECK: Only append if the list is empty OR the timestamp is different
            if not input_list or formatted_time != input_list[-1][0]:
                input_list.append((formatted_time, velocity_km_h))
            else:
                logger.debug("Skipping duplicate timestamp", time_stamp=formatted_time)

    except Exception as e:
        logger.error("An error occurred during data retrieval", error=repr(e))

    if len(input_list) < 5:
        logger.info("Not enough Data for scoring",
                    vehicle_id=id, input_amount=len(input_list))
        return JSONResponse(status_code=204, content=None)
    else:
        sorted_data = sorted(input_list, key=lambda x: x[0], reverse=False)
        logger.info("Calculating batch: ", batch=sorted_data)
        result = score_trip(sorted_data)
        # await nats_client.publish_message(subject=f"scoring.{id}",
        #                                   message=ScoringMessage(vehicle_id=id, score=str(result.score),
        #                                                          suggestions=list(result.suggestions)))
        return JSONResponse(status_code=200,
                            content={"vehicle_id": id, "score": result.score, "suggestions": result.suggestions})


async def normalize_timestamps(end_time: datetime | None, start_time: datetime | None) -> tuple[datetime, datetime]:
    if start_time and start_time.tzinfo is None:
        # Attach UTC timezone to the naive datetime
        start_time = start_time.replace(tzinfo=timezone.utc)

    if end_time and end_time.tzinfo is None:
        end_time = end_time.replace(tzinfo=timezone.utc)
    return end_time, start_time
