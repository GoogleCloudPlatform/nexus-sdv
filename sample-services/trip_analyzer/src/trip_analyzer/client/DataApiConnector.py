import asyncio
import time

import httpx
from grpclib.client import Channel

from trip_analyzer.client.generated.dataapi.v1 import TelemetryDataApiStub
from trip_analyzer.config.config import settings
from trip_analyzer.config.logging import logger

# Ask for a new token slightly before the old one expires, so a long-running
# stream never starts with a token that dies mid-call.
_TOKEN_EXPIRY_MARGIN_SECONDS = 30


class DataApiConnector:
    """Talks to the Data API.

    Since #558 the Data API requires a Keycloak access token, so every call
    carries a bearer token this service mints for itself with the
    client_credentials flow. The channel is plaintext: the Data API is
    cluster-internal, like the platform's other internal services.
    """

    def __init__(self):
        self._channel: Channel | None = None
        self.client: TelemetryDataApiStub | None = None
        self._token: str | None = None
        self._token_expires_at: float = 0.0

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

    async def _access_token(self) -> str:
        """Returns a valid access token, fetching a new one only when needed."""
        if self._token and time.monotonic() < self._token_expires_at:
            return self._token

        logger.info("Requesting an access token", target=settings.keycloak_token_uri)
        async with httpx.AsyncClient(timeout=settings.data_api_timeout) as http:
            response = await http.post(
                settings.keycloak_token_uri,
                data={
                    "grant_type": "client_credentials",
                    "client_id": settings.keycloak_client_id,
                    "client_secret": settings.keycloak_client_secret,
                },
            )
            response.raise_for_status()
            payload = response.json()

        self._token = payload["access_token"]
        lifetime = int(payload.get("expires_in", 60))
        self._token_expires_at = time.monotonic() + max(lifetime - _TOKEN_EXPIRY_MARGIN_SECONDS, 10)
        return self._token

    async def get_client(self) -> TelemetryDataApiStub:
        """A stub carrying a current token.

        A stub holds its metadata for its lifetime, so this returns a fresh one
        rather than a cached stub with a token that will expire. The channel
        underneath is reused; only the metadata is new.
        """
        token = await self._access_token()
        return TelemetryDataApiStub(
            self._channel,
            metadata=[("authorization", f"Bearer {token}")],
        )

    async def close(self):
        """Gracefully closes the channel."""
        if self._channel:
            self._channel.close()
            logger.info("gRPC channel closed")
