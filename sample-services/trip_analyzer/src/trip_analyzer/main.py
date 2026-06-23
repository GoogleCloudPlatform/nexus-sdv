import asyncio
from contextlib import asynccontextmanager
from fastapi import FastAPI
from trip_analyzer.config.logging import setup_logging, logger
from trip_analyzer.client.nats_client import NatsConnector
from typing import List, Union

from trip_analyzer.api.router import api_router
from trip_analyzer.config.config import settings
from trip_analyzer.client.DataApiConnector import DataApiConnector
from trip_analyzer.core.processor import Processor
from trip_analyzer.core.scheduler import TripScheduler

setup_logging()


def split_comma_string(v: Union[str, List[str]]) -> List[str]:
    if isinstance(v, str):
        # Split by comma and strip whitespace from each VIN
        return [item.strip() for item in v.split(",") if item.strip()]
    return v


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Application starting",
                config=settings.model_dump(context={"redact": True}))  # Log config for debugging

    app.state.nats_client = NatsConnector()
    await app.state.nats_client.connect()

    app.state.data_api = DataApiConnector()
    await app.state.data_api.connect()
    await app.state.data_api.is_healthy()

    processor = Processor(app.state.data_api.get_client(), app.state.nats_client)

    scheduler = TripScheduler(processor)
    app.state.scheduler = scheduler
    scheduler.start()

    vins_to_schedule = split_comma_string(settings.scheduled_vins)
    for vin in vins_to_schedule:
        app.state.scheduler.schedule_analysis(vin, settings.data_poll_interval)

    yield

    scheduler.shutdown()
    await app.state.data_api.close()
    await app.state.nats_client.close()


# 2. Initialize the App
app = FastAPI(
    title="trip-analyzer",
    version="1.0.0",
    lifespan=lifespan
)

# 3. Include Routers
app.include_router(api_router)
