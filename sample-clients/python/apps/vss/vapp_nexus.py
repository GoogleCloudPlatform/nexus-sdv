import asyncio
import logging
from kuksa_client.grpc.aio import VSSClient
from kuksa_client.grpc import Datapoint

# Integration of your new Nexus SDK package
from nexus_sdk.car import NexusCar
from nexus_sdk import telemetry

# Local config import (ensure __init__.py exists in apps/vss/)
try:
    from . import config
except ImportError:
    import config

class NexusTelemetryVApp:
    def __init__(self, kuksa_client):
        self.kuksa_client = kuksa_client
        # Initialize Nexus SDK (automatically finds nexus_client_config.json in root)
        self.nexus_car = NexusCar()
        self.vin = config.VIN

    async def on_vss_update(self, path, value):
        print("--- [Inbound VSS Update] ---")
        print(f"DEBUG: Raw data from Kuksa -> {path}: {value}")

        # Example Logic: Determine status based on value
        status = "NORMAL"
        if path == "Vehicle.Speed" and value > 120:
            status = "CRITICAL_OVERSPEED"
            print(f"ALARM: Vehicle overspeed detected: {value} km/h")
        
        # Prepare data for Nexus Telemetry (Protobuf format)
        reading = telemetry.SensorReading(
            sensor=path,
            value=str(value),
            data_type=telemetry.DataType.DYNAMIC
        )

        print("DATA: Packaging for Bigtable ingestion:")
        print(f"   | Path: {path} | Status: {status} | Value: {value}")

        # Send to Cloud via Nexus SDK (NATS)
        try:
            await self.nexus_car.send_telemetry_batch([reading])
            print("INFO: Successfully forwarded to Bigtable via NATS.")
        except Exception as e:
            print(f"❌ [CLOUD] Transmission failed: {e}")
        
        print("----------------------------\n")

    async def run(self):
        print(f"VApp for '{self.vin}' (Model: {config.VEHICLE_MODEL}) started.")
        print(f"LISTENING: gRPC stream from {config.KUKSA_IP}:{config.KUKSA_PORT}...")
        
        # Define paths to monitor
        monitored_paths = ['Vehicle.Speed']
        
        # Subscription via Kuksa Client
        async for updates in self.kuksa_client.subscribe_current_values(monitored_paths):
            for path, dp in updates.items():
                if dp is not None:
                    await self.on_vss_update(path, dp.value)

async def run():
    # Set logging to INFO to see NATS/SDK status
    logging.basicConfig(level=logging.INFO)
    
    try:
        async with VSSClient(config.KUKSA_IP, config.KUKSA_PORT) as client:
            vapp = NexusTelemetryVApp(client)
            
            # Initial test trigger
            print("TEST: Simulating initial data point...")
            target_path = getattr(config, 'PATH_SPEED', 'Vehicle.Speed')
            await client.set_current_values({target_path: Datapoint(130.0)})
            
            await vapp.run()
    except Exception as e:
        print(f"❌ ERROR: Connection to Databroker failed. Is Docker running? ({e})")

def main():
    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        print("\nNexus VApp terminated by user.")

if __name__ == "__main__":
    main()        