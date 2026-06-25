import os

import pytest
from unittest.mock import patch, AsyncMock, PropertyMock

from starlette.testclient import TestClient

from trip_analyzer.main import app


async def log_request(request):
    print(f"\n>>>> REQUEST: {request.method} {request.url}")
    # Be careful logging bodies if they are massive
    if request.content:
        print(f"BODY: {request.content.decode()}")


async def log_response(response):
    print(f"<<<< RESPONSE: {response.status_code}")
    await response.aread()  # Ensure body is read for logging
    print(f"BODY: {response.text}")


@pytest.fixture
def client():
    with patch("trip_analyzer.client.nats_client.NatsConnector.connect", new_callable=AsyncMock), \
            patch("trip_analyzer.client.nats_client.NatsConnector.close", new_callable=AsyncMock), \
            patch("trip_analyzer.client.nats_client.NatsConnector.is_connected", new_callable=PropertyMock,
                  return_value=True):
        with patch("trip_analyzer.client.DataApiConnector.DataApiConnector.connect", new_callable=AsyncMock), \
                patch("trip_analyzer.client.DataApiConnector.DataApiConnector.is_healthy", new_callable=AsyncMock,
                      return_value=True), \
                patch("trip_analyzer.client.DataApiConnector.DataApiConnector.get_client") as mock_get_client:
            # 2. Create the AsyncMock that acts as the gRPC Stub
            mock_stub = AsyncMock()

            #        3. Make the sync method return the async stub immediately
            mock_get_client.return_value = mock_stub

        with TestClient(app, base_url="http://test") as ac:
            app.state.nats_client = AsyncMock()
            app.state.data_api = AsyncMock()
            app.state.data_api.client = AsyncMock()
            yield ac
