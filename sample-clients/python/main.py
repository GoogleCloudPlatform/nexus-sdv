import argparse
import factory
import asyncio
import json
import time
from pathlib import Path
from nexus_sdk import car as nexus_car
from apps.simple_sim.simple_telemetry_sim import SimpleTelemetrySim

def parse_args():
    
    parser = argparse.ArgumentParser(description="Vehicle client for SDV telemetry system")
    parser.add_argument("-vin", required=True)
    parser.add_argument("-pki_strategy", required=True, choices=["local", "remote"])
    parser.add_argument("-factory-cert", required=True)
    parser.add_argument("-factory-key", required=True)
    parser.add_argument("-registration-url", required=True)
    parser.add_argument("-interval", type=int, default=5)
    return parser.parse_args()

def prepare_car(args):
    """this is needed only once for any vehicle"""
    # 1. Factory Zertifikate vorbereiten
    client_key_path, client_csr_path, client_certificate_path = factory.prepare_factory_cert(
        args.vin,
        args.factory_cert,
        args.factory_key,
    )

    # 2. Register (Synchroner Aufruf aus car-comp)
    keycloak_url, nats_url, operational_key_path = nexus_car.register(
        args.vin,
        args.pki_strategy,
        client_key_path,
        client_csr_path,
        client_certificate_path,
        args.registration_url,
    )

    return keycloak_url, nats_url, operational_key_path

def main():
    args = parse_args()
    keycloak_url, nats_url, operational_key_path = prepare_car(args)

    # 3. Nexus Config zusammenbauen & speichern
    nexus_client_config = {
        "vin": args.vin,
        "nats_url": nats_url,
        "keycloak_url": keycloak_url,
        "operational_cert_path": str(Path(nexus_car.OPERATIONAL_CERTIFICATE_PATH).absolute()),
        "operational_key_path": str(Path(operational_key_path).absolute()),
        "client_id": f"nexus-{args.vin}"
    }
    
    with open("nexus_client_config.json", "w") as f:
        json.dump(nexus_client_config, f, indent=4)
    print("\n✅ nexus_client_config.json created.")

    # 3. Instanziierung des neuen Services ohne Parameter-Übergabe
    sim_service = SimpleTelemetrySim("nexus_client_config.json")

    try:
        asyncio.run(sim_service.run_simulation(args.interval))
    except KeyboardInterrupt:
        print("\nStopped by KeyboardInterrupt.")

if __name__ == "__main__":
    main()