import pytest
from trip_analyzer.config.config import Settings


def test_config_defaults():
    """Test that the application uses defaults when no env vars are set."""
    # We instantiate a fresh Settings object for the test
    # Passing _env_file=None ensures it doesn't even look for your local .env
    settings = Settings(_env_file=None)

    assert settings.nats_stream == "STREAM_PLACEHOLDER"
    assert settings.env == "dev"
    assert settings.data_api_timeout == 15


def test_config_env_overrides(monkeypatch):
    """Test that environment variables correctly override defaults."""
    # 1. Set environment variables (simulating 'export MYAPP_NATS_STREAM=...')
    # Note: If you used 'env_prefix' in your config, use that prefix here!
    monkeypatch.setenv("NATS_URL", "nats://prod-cluster:4222")
    monkeypatch.setenv("NATS_STREAM", "PROD_STREAM")
    monkeypatch.setenv("DATA_API_TIMEOUT", "30")

    # 2. Instantiate settings
    settings = Settings(_env_file=None)

    # 3. Verify overrides
    assert settings.nats_url == "nats://prod-cluster:4222"
    assert settings.nats_stream == "PROD_STREAM"
    assert settings.data_api_timeout == 30


def test_config_validation_error(monkeypatch):
    """Test that invalid types trigger a Pydantic ValidationError."""
    from pydantic import ValidationError

    # Passing a string to an integer field
    monkeypatch.setenv("DATA_API_TIMEOUT", "not-a-number")

    with pytest.raises(ValidationError):
        Settings(_env_file=None)
