import asyncio
from nexus_sdk import telemetry
from nexus_sdk.car import NexusCar
import math 

class SimpleTelemetrySim:
    def __init__(self, config_path="nexus_client_config.json"):
        
        self.car = NexusCar(config_path)
        self.interval = 5 

    async def run_simulation(self, interval=None):
        """Telemetry Simulation."""
        if interval:
            self.interval = interval
            
        print(f"Nexus simulation VIN {self.car.config['vin']} started...")
        
        index = 0
        soc = 100.0 # Startwert Batterie 100%
        while True:
            # Simple Simulation
            speed = 50.0 + (math.sin(index * 0.2) * 20.0) # Schwankt zwischen 30 und 70
            soc = max(0.0, soc - 0.1) # Batterie sinkt pro Intervall um 0.1%
            brake_pos = 100.0 if speed < 35.0 else 0.0 # "Bremst" wenn zu langsam
            readings = [
                # --- STATIC DATA ---
                telemetry.SensorReading(
                    sensor="Vehicle.VehicleIdentification.Model",
                    value="Nexus-SDV-Prototype-V1",
                    data_type=telemetry.DataType.STATIC,
                ),
                telemetry.SensorReading(
                    sensor="Vehicle.Powertrain.FuelSystem.TankCapacity",
                    value="85", # 
                    data_type=telemetry.DataType.STATIC,
                ),

                # --- DYNAMIC DATA ---
                telemetry.SensorReading(
                    sensor="Vehicle.Speed",
                    value=f"{speed:.2f}",
                    data_type=telemetry.DataType.DYNAMIC,
                ),
                telemetry.SensorReading(
                    sensor="Vehicle.Powertrain.Battery.StateOfCharge",
                    value=f"{soc:.1f}",
                    data_type=telemetry.DataType.DYNAMIC,
                ),
                telemetry.SensorReading(
                    sensor="Vehicle.Chassis.Brake.PedalPosition",
                    value=str(brake_pos),
                    data_type=telemetry.DataType.DYNAMIC,
                )
            ]

            # sendig via cloud agent
            await self.car.send_telemetry_batch(readings)
    
            print(f"[NATS] Batch {index} sent: Speed={speed:.1f}, SoC={soc:.1f}%")
            
            index += 1
            await asyncio.sleep(self.interval)