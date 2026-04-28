# simulator.py
import asyncio
import random
from kuksa_client.grpc.aio import VSSClient
from kuksa_client.grpc import Datapoint

# Local config import (ensure __init__.py exists in apps/vss/)
try:
    from . import config
except ImportError:
    import config

async def simulate_vehicle():
    print(f"Nexus-SDV Vehicle Simulator started.")
    print(f"Connecting to Kuksa at {config.KUKSA_IP}:{config.KUKSA_PORT}...")
    
    try:
        async with VSSClient(config.KUKSA_IP, config.KUKSA_PORT) as client:
            speed = 50.0
            while True:
                # Simulating realistic driving behavior
                # Speed fluctuates randomly between -5.0 and +7.0 km/h
                change = random.uniform(-5.0, 7.0)
                speed = max(0.0, min(220.0, speed + change))
                
                # Format speed for display
                formatted_speed = f"{speed:.2f}"
                print(f"SENDING VSS: {config.PATH_SPEED} = {formatted_speed} km/h")
                
                await client.set_current_values({
                    config.PATH_SPEED: Datapoint(speed)
                })
                
                # Wait 2 seconds until the next update
                await asyncio.sleep(2)
                
    except Exception as e:
        print(f"❌ Simulator error: {e}")


def main():
    """Synchronous entry point for the simulator"""
    try:
        asyncio.run(simulate_vehicle())
    except KeyboardInterrupt:
        print("\nSimulator stopped by user.")

if __name__ == "__main__":
    main()
