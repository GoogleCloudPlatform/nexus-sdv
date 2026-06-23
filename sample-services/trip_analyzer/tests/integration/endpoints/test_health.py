import pytest
from httpx import AsyncClient, ASGITransport
from trip_analyzer.main import app


@pytest.mark.asyncio
async def test_health_check(client):
    response = client.get("/health")

    assert response.status_code == 200
    json = response.json()
    assert json["status"] == "healthy"
    assert json["grpc"] == "Up"
    assert json["nats"] == "Up"
