import logging
from mypy.config_parser import split_commas

from pydantic_settings import BaseSettings, SettingsConfigDict
from typing import List, Union
from pydantic import Field, field_validator


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
    data_poll_interval: int = 5

    # App Environment
    env: str = "dev"
    debug: bool = False

    scheduled_vins: str = "vin1"

    # Automatically load from a .env file if it exists
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")


# Instantiate as a singleton
settings = Settings()
