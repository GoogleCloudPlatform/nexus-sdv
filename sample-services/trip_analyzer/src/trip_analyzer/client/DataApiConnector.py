from typing import AsyncIterator

from betterproto.lib.pydantic.google.protobuf import Duration
from grpclib.client import Channel
from requests.packages import target
from datetime import (
    datetime,
    timedelta,
)

import asyncio
from trip_analyzer.client.generated.dataapi.v1 import TelemetryDataApiStub, GetTelemetryDataRequest, TimeRange, \
    TelemetryPoint
from trip_analyzer.config.config import settings
from trip_analyzer.config.logging import logger


class DataApiConnector:
    def __init__(self):
        self._channel: Channel | None = None
        self.client: TelemetryDataApiStub | None = None

    async def is_healthy(self) -> bool:
        logger.info(f"Checking connection to Data-Api", target=settings.data_api_url)
        if not self._channel:
            logger.error(f"Channel not initialized", target=settings.data_api_url)
            return False

        try:
            await asyncio.wait_for(self._channel.__connect__(), timeout=settings.data_api_timeout)
            logger.info(f"Successfully connected to Data-API", target=settings.data_api_url)
            return True
        except (asyncio.TimeoutError, Exception):
            logger.error(f"Could not establish connection to Data-Api", target=settings.data_api_url)
            return False

    async def connect(self):
        """Initializes the connection to the external gRPC service."""
        logger.info(f"Initializing connection with Data-Api: {settings.data_api_url}", target=settings.data_api_url)
        host, port = settings.data_api_url.split(":")

        self._channel = Channel(host, int(port))
        self.client = TelemetryDataApiStub(self._channel)

    def get_client(self) -> TelemetryDataApiStub:
        return self.client

    async def close(self):
        """Gracefully closes the channel."""
        if self._channel:
            self._channel.close()
            logger.info("gRPC channel closed")
