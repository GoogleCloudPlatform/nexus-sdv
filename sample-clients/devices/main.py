import argparse
import asyncio
import base64
import json
import os
import shutil
import sys
import uuid
from pathlib import Path


def _ensure_proto_generated():
    script_dir = Path(__file__).parent
    proto_out = script_dir / "proto"
    if (proto_out / "telemetry_pb2.py").exists():
        return

    print("Generating protobuf files...")
    from grpc_tools import protoc

    if sys.version_info >= (3, 9):
        from importlib import resources
        proto_include = str((resources.files("grpc_tools") / "_proto").resolve())
    else:
        import pkg_resources
        proto_include = pkg_resources.resource_filename("grpc_tools", "_proto")

    proto_source = str((script_dir / ".." / ".." / "proto").resolve())
    proto_out.mkdir(exist_ok=True)
    (proto_out / "__init__.py").touch()

    ret = protoc.main([
        "grpc_tools.protoc",
        f"--proto_path={proto_source}",
        f"--proto_path={proto_include}",
        f"--python_out={proto_out}",
        f"--pyi_out={proto_out}",
        "telemetry.proto",
    ])
    if ret != 0:
        sys.exit(f"Failed to generate protobuf files (protoc exit code {ret})")
    print("Protobuf files generated.")


_ensure_proto_generated()

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
        if not Path(args.factory_cert).exists():
            raise FileNotFoundError(f"Factory certificate not found: {args.factory_cert}")
        if not Path(args.factory_key).exists():
            raise FileNotFoundError(f"Factory key not found: {args.factory_key}")
        factory_cert, factory_key = args.factory_cert, args.factory_key

    # Register and get operational certificate (generates new operational key)
    keycloak_server_url, nats_server_url = device.register(
        args.uid,
        args.pki_strategy,
        factory_key,
        factory_cert,
        args.registration_url,
        str(history_dir),
    )

    urls = {"keycloak_url": keycloak_server_url, "nats_url": nats_server_url}
    (history_dir / "urls.json").write_text(json.dumps(urls, indent=2))
    print(f"Written urls.json to {history_dir}")

    # Copy final files to output directory
    output_dir = Path(args.output).expanduser()
    cert_output_dir = output_dir / "certs"
    cert_output_dir.mkdir(parents=True, exist_ok=True)
    for filename in ("operational.crt.pem", "operational.key.pem"):
        shutil.copy(history_dir / filename, cert_output_dir / filename)
    shutil.copy(history_dir / "keycloak_ca.pem", cert_output_dir / "ca.crt.pem")
    shutil.copy(history_dir / "urls.json", output_dir / "urls.json")
    print(f"Copied final files to {args.output}")

    if args.with_telemetry:
        # Authenticate with Keycloak using operational certificate + operational key
        access_token, expires_in = device.get_access_token(
            keycloak_server_url,
            cert_output_dir,
        )

        asyncio.run(device.send_data(args.uid, args.interval, nats_server_url, access_token))


if __name__ == "__main__":
    main()
