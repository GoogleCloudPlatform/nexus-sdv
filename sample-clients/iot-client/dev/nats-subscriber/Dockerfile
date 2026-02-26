FROM python:3.13-slim

RUN pip install --no-cache-dir nats-py protobuf grpcio-tools

WORKDIR /app

COPY proto/telemetry.proto proto/
RUN python -m grpc_tools.protoc --python_out=. -Iproto proto/telemetry.proto

COPY sample-clients/iot-client/dev/nats-subscriber/subscriber.py .

CMD ["python", "-u", "subscriber.py"]
