import argparse
import asyncio
import base64
import os
import shutil
import uuid
from pathlib import Path

import device
import factory

DEFAULT_OPERATIONAL_PATH = "certificates/"
DEFAULT_PKI_STRATEGY = "local"
DEFAULT_REGISTRATION_URL = "https://localhost:8080"
BOOTSTRAP_ENV_PATH = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "iac", "bootstrapping", ".bootstrap_env"
)


def load_bootstrap_env():
    if not os.path.isfile(BOOTSTRAP_ENV_PATH):
        return {}
    env = {}
    with open(BOOTSTRAP_ENV_PATH) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            env[key.strip()] = value.strip().strip('"').strip("'")
    return env


def parse_args():
    bootstrap = load_bootstrap_env()

    pki_strategy = bootstrap.get("PKI_STRATEGY", DEFAULT_PKI_STRATEGY)
    registration_hostname = bootstrap.get("REGISTRATION_HOSTNAME")
    registration_url = (
        f"https://{registration_hostname}:8080"
        if registration_hostname
        else DEFAULT_REGISTRATION_URL
    )

    parser = argparse.ArgumentParser(
        description="Device client for SDV telemetry system"
    )
    parser.add_argument(
        "-uid",
        default=base64.urlsafe_b64encode(uuid.uuid4().bytes).rstrip(b"=").decode(),
        help="device identifier (default: randomly generated 22-char base64url ID)",
    )
    parser.add_argument(
        "-pki_strategy",
        default=pki_strategy,
        choices=["local", "remote"],
        help="PKI strategy: 'local' or 'remote'",
    )
    parser.add_argument(
        "-factory-cert",
        default=None,
        help="Path to factory certificate chain (PEM). Defaults to vehicle-<uid>-factory[-gcp]-chain.pem",
    )
    parser.add_argument(
        "-factory-key",
        default=None,
        help="Path to factory private key (PEM). Defaults to vehicle-<uid>-factory[-gcp]-key.pem",
    )
    parser.add_argument(
        "-registration-url",
        default=registration_url,
        help="Registration server URL (e.g., https://registration.example.com:8080)",
    )
    parser.add_argument(
        "-output",
        type=str,
        default=DEFAULT_OPERATIONAL_PATH,
        help="Output directory path for the generated operation key and certificate",
    )
    parser.add_argument(
        "-with-telemetry",
        action="store_true",
        default=False,
        help="Also sends fake telemetry data",
    )
    parser.add_argument(
        "-interval",
        type=int,
        default=5,
        help="Telemetry interval in seconds (default: 5)",
    )
    return parser.parse_args()


def main():
    args = parse_args()

    print(f"Starting device registration for uid: {args.uid}")
    print(f"PKI Strategy: {args.pki_strategy}")
    print(f"Registration server: {args.registration_url}")
    print(f"Output directory for operational files: {args.output}")
    print()

    history_dir = Path("history") / args.uid
    history_dir.mkdir(parents=True, exist_ok=True)

    # Step 0: Obtain factory certificate
    if args.pki_strategy == "local":
        print("Step 0: Generating factory certificate...")
        factory_cert, factory_key = factory.generate_factory_cert(args.uid, str(history_dir))
        print()
    else:
        if args.factory_cert is None or args.factory_key is None:
            print("Error: -factory-cert and -factory-key are required for remote PKI strategy.")
            raise SystemExit(1)
        factory_cert, factory_key = args.factory_cert, args.factory_key

    # Step 1: Prepare factory certificate for use in registration
    client_key_path, client_csr_path, client_certificate_path = factory.prepare_factory_cert(
        args.uid,
        factory_cert,
        factory_key,
        str(history_dir),
    )

    # Register and get operational certificate (generates new operational key)
    keycloak_server_url, nats_server_url = device.register(
        args.uid,
        args.pki_strategy,
        client_key_path,
        client_csr_path,
        client_certificate_path,
        args.registration_url,
        str(history_dir),
    )

    urls_env = f'KEYCLOAK_URL="{keycloak_server_url}"\nNATS_URL="{nats_server_url}"\n'
    (history_dir / "urls.env").write_text(urls_env)
    print(f"Written urls.env to {history_dir}")

    # Copy final files to output directory
    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)
    for filename in ("urls.env", "operational.crt.pem", "operational.key.pem"):
        shutil.copy(history_dir / filename, output_dir / filename)
    shutil.copy(history_dir / "keycloak_ca.pem", output_dir / "ca.crt.pem")
    print(f"Copied final files to {args.output}")

    if args.with_telemetry:
        # Authenticate with Keycloak using operational certificate + operational key
        access_token, expires_in = device.get_access_token(
            keycloak_server_url,
            args.output,
        )

        asyncio.run(device.send_data(args.uid, args.interval, nats_server_url, access_token))


if __name__ == "__main__":
    main()
