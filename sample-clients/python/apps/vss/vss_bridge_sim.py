import asyncio
import logging
import random
from kuksa_client.grpc.aio import VSSClient
from kuksa_client.grpc import Datapoint

# Integration of your Nexus SDK
from nexus_sdk.car import NexusCar
from nexus_sdk import telemetry
from . import config

async def run():
    # 1. Initialize Nexus Client
    try:
        nexus_vehicle = NexusCar()
        print("INFO: Nexus SDK initialized (mTLS & NATS connection ready)")
    except Exception as e:
        print(f"❌ ERROR: Failed to initialize Nexus SDK: {e}")
        return

    # 2. Connection to Kuksa Broker
    try:
        async with VSSClient(config.KUKSA_IP, config.KUKSA_PORT) as client:
            print(f"INFO: VSS Bridge connected to Kuksa at {config.KUKSA_IP}:{config.KUKSA_PORT}")

            # Define the paths (Note: if TractionBattery fails, try simpler ones)
            monitored_paths = [
                'Vehicle.Speed',
                'Vehicle.Powertrain.CombustionEngine.Speed',
                'Vehicle.Powertrain.TractionBattery.StateOfCharge.Current',
                'Vehicle.Chassis.Brake.PedalPosition'
            ]

            # --- TASK 1: Multi-Signal Simulation (Producer) ---
            async def drive_car():
                speed = 0.0
                soc = 85.0
                while True:
                    try:
                        # Geschwindigkeit steigt, fällt aber bei "Bremsen"
                        is_braking = random.random() < 0.2  # 20% Chance zu bremsen
                        
                        if is_braking:
                            brake = random.uniform(20.0, 80.0)
                            speed = max(0.0, speed - 10.0)
                        else:
                            brake = 0.0
                            speed = (speed + random.uniform(2.0, 5.0)) % 160
                        
                        rpm = 800 + (speed * 40) + random.uniform(-50, 50)
                        soc = max(0.0, soc - 0.05)

                        # We use a loop here to set values one by one to see which one fails
                        data_to_send = {
                            'Vehicle.Speed': Datapoint(speed),
                            'Vehicle.Powertrain.CombustionEngine.Speed': Datapoint(rpm),
                            'Vehicle.Powertrain.TractionBattery.StateOfCharge.Current': Datapoint(soc),
                            'Vehicle.Chassis.Brake.PedalPosition': Datapoint(brake)
                        }
                        
                        await client.set_current_values(data_to_send)
                        
                    except Exception as e:
                        # This prevents the whole app from dying if one path is wrong
                        print(f"WARN: Simulation update partially failed (maybe a path is missing?): {e}")
                    
                    # THE CRITICAL SLEEP: Control the frequency
                    await asyncio.sleep(2)

            # Start simulation in the background
            asyncio.create_task(drive_car())

            # --- TASK 2: Nexus Relay (Consumer) ---
            print(f"LISTENING: Nexus Relay subscribing to: {monitored_paths}")
            
            async for updates in client.subscribe_current_values(monitored_paths):
                readings = []
                # DEBUG: Zeige uns im Terminal, was Kuksa gerade wirklich schickt
                # print(f"DEBUG: Received from Kuksa: {list(updates.keys())}") 

                for path, dp in updates.items():
                    # WICHTIG: Prüfen, ob dp existiert UND einen Wert hat
                    if dp is not None and dp.value is not None:
                        try:
                            # Sicherstellen, dass wir alles zu String konvertieren
                            val_str = f"{float(dp.value):.2f}"
                            
                            readings.append(telemetry.SensorReading(
                                sensor=path,
                                value=val_str,
                                data_type=telemetry.DataType.DYNAMIC
                            ))
                        except (ValueError, TypeError):
                            # Falls ein Wert mal kein Float ist (z.B. Enum oder String)
                            readings.append(telemetry.SensorReading(
                                sensor=path,
                                value=str(dp.value),
                                data_type=telemetry.DataType.DYNAMIC
                            ))
                
                if readings:
                    try:
                        await nexus_vehicle.send_telemetry_batch(readings)
                        # Präzises Logging, was rausging
                        sensors = [r.sensor.split('.')[-1] for r in readings]
                        print(f"DATA: Sent to Nexus -> {sensors}")
                    except Exception as e:
                        print(f"❌ CLOUD ERROR: {e}")

    except Exception as e:
        print(f"❌ ERROR: Failed to connect to Kuksa Broker: {e}")

def main():
    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        print("\nINFO: Nexus VApp terminated by user.")

if __name__ == "__main__":
    main()