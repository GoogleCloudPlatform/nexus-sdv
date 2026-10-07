import logging
from mypy.config_parser import split_commas

from pydantic_settings import BaseSettings, SettingsConfigDict
from typing import List, Union
from pydantic import Field, field_validator, field_serializer


class Settings(BaseSettings):
    # NATS Configuration
    nats_host: str = Field(default="localhost")
    nats_port: str = Field(default="4222")
    nats_stream: str = "STREAM_PLACEHOLDER"
    nats_user: str = "setInEnv"
    nats_password: str = "setInEnv"

    # gRPC Configuration
    data_api_url: str = Field(default="localhost:50051")
    data_api_timeout: int = 15
    # The Data API requires a token since #558.
    keycloak_token_uri: str = Field(default="setInEnv")
    keycloak_client_id: str = Field(default="factory-operator")
    keycloak_client_secret: str = Field(default="setInEnv")
    data_poll_interval: int = 5          # how often a score is produced (schedule cadence, seconds)
    scoring_window_seconds: int = 15     # how much recent telemetry each score looks at (seconds)

    # App Environment
    env: str = "dev"
    debug: bool = False

    scheduled_vins: str = "vin1"

    @field_serializer("keycloak_client_secret")
    def _redact_keycloak_client_secret(self, value: str, info):
        return "***"

    @field_serializer("nats_password")
    def _redact_nats_password(self, value: str, info):
        # Redact only when dumped with context={"redact": True} (e.g. the startup
        # config log). Plain attribute access (settings.nats_password) is unaffected,
        # so the NATS client still receives the real secret.
        if info.context and info.context.get("redact"):
            return "***REDACTED***"
        return value

    # Automatically load from a .env file if it exists
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")


# Instantiate as a singleton
settings = Settings()
