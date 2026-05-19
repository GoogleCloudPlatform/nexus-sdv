import json
import logging
import asyncio
import os
import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware

# Nexus SDK Integration
from nexus_sdk.car import NexusCar
from nexus_sdk import telemetry

SENSOR = "battery.temperature"
logger = logging.getLogger("uvicorn.error")

class NexusSimulatorApp(FastAPI):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.nexus_vehicle = None
        self.example_data = {}

app = NexusSimulatorApp()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.on_event("startup")
async def startup_event():
    try:
        app.nexus_vehicle = NexusCar()
        logger.info("INFO: Nexus SDK initialized for VHAL Simulator")
    except Exception as e:
        logger.error(f"❌ ERROR: Failed to initialize Nexus SDK: {e}")

    base_path = os.path.dirname(__file__)
    json_path = os.path.join(base_path, "example_data.json")
    try:
        with open(json_path, "r") as file:
            app.example_data = json.load(file)
            logger.info(f"INFO: Loaded datasets from {json_path}")
    except FileNotFoundError:
        logger.error(f"❌ ERROR: example_data.json not found")

@app.get("/simulations")
async def get_simulations():
    return {"available_simulations": app.example_data}

@app.post("/start-simulation/{dataset}")
async def start_simulation(dataset: str):
    if dataset not in app.example_data:
        raise HTTPException(status_code=404, detail="Dataset not found")

    if not app.nexus_vehicle:
        raise HTTPException(status_code=500, detail="Nexus SDK not initialized")

    # Wir starten die Simulation in einem Hintergrund-Task, 
    # damit der API-Call sofort "Started" zurückgeben kann.
    asyncio.create_task(run_simulation_task(dataset))

    return {
        "status": "started",
        "dataset": dataset,
        "samples_count": len(app.example_data[dataset])
    }

async def run_simulation_task(dataset: str):
    """Iteriert durch die Daten und sendet sie mit Pause"""
    logger.info(f"🚀 Simulation started: {dataset}")
    
    for value in app.example_data[dataset]:
        reading = telemetry.SensorReading(
            sensor=SENSOR,
            value=str(value),
            data_type=telemetry.DataType.DYNAMIC
        )
        
        try:
            # Einzeln senden, damit jeder Punkt einen eigenen Zeitstempel bekommt
            await app.nexus_vehicle.send_telemetry_batch([reading])
            logger.info(f"DATA: Sent {SENSOR} = {value}")
        except Exception as e:
            logger.error(f"❌ ERROR sending sample: {e}")
        
        # 1 Sekunde Pause zwischen den Werten für eine schöne Kurve im Bigtable Studio
        await asyncio.sleep(1)

    logger.info(f"🏁 Simulation completed: {dataset}")

def main():
    uvicorn.run("apps.vhal.main:app", host="0.0.0.0", port=8080, reload=True)

if __name__ == "__main__":
    main()