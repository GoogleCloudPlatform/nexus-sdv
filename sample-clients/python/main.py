import argparse
import base64
import datetime
import factory
import asyncio
import json
import time
from pathlib import Path
from nexus_sdk import car as nexus_car
from apps.simple_sim.simple_telemetry_sim import SimpleTelemetrySim

CONFIG_FILE = "nexus_client_config.json"


def parse_args():
    parser = argparse.ArgumentParser(description="Vehicle client for SDV telemetry system")
    parser.add_argument("-vin", default="VEHICLE001")
    parser.add_argument("-interval", type=int, default=5)
    # Registration arguments — only used when existing certs are missing/expired
    parser.add_argument("-pki_strategy", choices=["local", "remote"], default="remote")
    parser.add_argument("-factory-cert", default=None)
    parser.add_argument("-factory-key", default=None)
    parser.add_argument("-registration-url", default=None)
    parser.add_argument("-keycloak-url", default=None,
                        help="Keycloak URL (written to config when reusing existing certs)")
    parser.add_argument("-nats-url", default=None,
                        help="NATS URL (written to config when reusing existing certs)")
    return parser.parse_args()


def _jwt_expiry(token: str) -> float:
    """Decode exp claim from a JWT without verifying the signature."""
    try:
        payload_b64 = token.split(".")[1]
        payload_b64 += "=" * (-len(payload_b64) % 4)
        payload = json.loads(base64.urlsafe_b64decode(payload_b64))
        return float(payload.get("exp", 0))
    except Exception:
        return 0.0


def existing_certs_valid() -> tuple[bool, str]:
    """
    Check whether the operational certificate and OIDC token on disk are still
    valid (> 60 s remaining). Returns (valid, access_token).
    """
    # Operational certificate
    cert_path = Path(nexus_car.OPERATIONAL_CERTIFICATE_PATH)
    if not cert_path.exists():
        print("No existing operational certificate found")
        return False, ""
    try:
        from cryptography import x509 as cx509
        cert = cx509.load_pem_x509_certificate(cert_path.read_bytes())
        now = datetime.datetime.now(datetime.timezone.utc)
        remaining = cert.not_valid_after_utc - now
        if remaining.total_seconds() < 60:
            print(f"Operational certificate expired at {cert.not_valid_after_utc}")
            return False, ""
        print(f"  Certificate valid until: {cert.not_valid_after_utc.isoformat()}")
    except Exception as e:
        print(f"Could not read operational certificate: {e}")
        return False, ""

    # OIDC access token
    token_path = Path(nexus_car.PROJECT_ROOT) / "certificates" / "oidc-access-token"
    if not token_path.exists():
        print("No existing access token found")
        return False, ""
    token = token_path.read_text().strip()
    if not token:
        print("Access token file is empty")
        return False, ""
    exp = _jwt_expiry(token)
    if exp <= time.time() + 60:
        print(f"Access token expired (exp={datetime.datetime.fromtimestamp(exp).isoformat()})")
        return False, ""
    print(f"  Token valid until:       {datetime.datetime.fromtimestamp(exp).isoformat()}")

    return True, token


def do_register(args) -> None:
    """Perform full PKI registration and write nexus_client_config.json."""
    if not args.factory_cert or not args.factory_key or not args.registration_url:
        raise SystemExit(
            "Error: -factory-cert, -factory-key, and -registration-url are required "
            "when existing certificates are missing or expired."
        )

    client_key_path, client_csr_path, client_certificate_path = factory.prepare_factory_cert(
        args.vin,
        args.factory_cert,
        args.factory_key,
    )

    keycloak_url, nats_url, operational_key_path = nexus_car.register(
        args.vin,
        args.pki_strategy,
        client_key_path,
        client_csr_path,
        client_certificate_path,
        args.registration_url,
    )

    config = {
        "vin": args.vin,
        "nats_url": nats_url,
        "keycloak_url": keycloak_url,
        "operational_cert_path": str(Path(nexus_car.OPERATIONAL_CERTIFICATE_PATH).absolute()),
        "operational_key_path": str(Path(operational_key_path).absolute()),
        "keycloak_ca_path": str(Path(nexus_car.REMOTE_KEYCLOAK_CA_PATH).absolute()),
        "client_id": f"nexus-{args.vin}",
    }
    with open(CONFIG_FILE, "w") as f:
        json.dump(config, f, indent=4)
    print(f"✅ {CONFIG_FILE} written.")


def main():
    args = parse_args()

    valid, _token = existing_certs_valid()

    if valid:
        print("✓ Existing certificates and token are valid — skipping registration")
        # Update config with current URLs if provided
        if Path(CONFIG_FILE).exists() and (args.keycloak_url or args.nats_url):
            with open(CONFIG_FILE) as f:
                cfg = json.load(f)
            if args.keycloak_url:
                cfg["keycloak_url"] = args.keycloak_url
            if args.nats_url:
                cfg["nats_url"] = args.nats_url
            # Always keep keycloak_ca_path up to date
            cfg["keycloak_ca_path"] = str(Path(nexus_car.REMOTE_KEYCLOAK_CA_PATH).absolute())
            with open(CONFIG_FILE, "w") as f:
                json.dump(cfg, f, indent=4)
    else:
        print("No valid existing certificates — starting registration flow...")
        do_register(args)
        # Patch URLs into config if overrides were provided
        if args.keycloak_url or args.nats_url:
            with open(CONFIG_FILE) as f:
                cfg = json.load(f)
            if args.keycloak_url:
                cfg["keycloak_url"] = args.keycloak_url
            if args.nats_url:
                cfg["nats_url"] = args.nats_url
            with open(CONFIG_FILE, "w") as f:
                json.dump(cfg, f, indent=4)

    sim_service = SimpleTelemetrySim(CONFIG_FILE)
    try:
        asyncio.run(sim_service.run_simulation(args.interval))
    except KeyboardInterrupt:
        print("\nStopped by KeyboardInterrupt.")


if __name__ == "__main__":
    main()
