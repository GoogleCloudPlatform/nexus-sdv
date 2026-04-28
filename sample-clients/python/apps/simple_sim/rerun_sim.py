import asyncio
from .simple_telemetry_sim import SimpleTelemetrySim

def main():

    sim_service = SimpleTelemetrySim("nexus_client_config.json")

    try:
        asyncio.run(sim_service.run_simulation(2))
    except KeyboardInterrupt:
        print("\nStopped by KeyboardInterrupt.")

if __name__ == "__main__":
    main()