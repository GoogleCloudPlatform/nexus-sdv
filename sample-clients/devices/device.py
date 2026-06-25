import sys
import math
import random
import nats
import asyncio
import requests
import shutil
import telemetry
from pathlib import Path
from keycloak import KeycloakOpenID, KeycloakError
from requests.exceptions import RequestException
from nats.aio.client import Client as NatsClient
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization, hashes
from cryptography import x509
from cryptography.x509.oid import NameOID

# Variables
UID = "DEVICE001"
DEVICE = "mcp"

OPERATIONAL_CERTIFICATE_FILE = "operational.crt.pem"
OPERATIONAL_KEY_FILE = "operational.key.pem"
OPERATIONAL_KEYCLOAK_CA_FILE = "keycloak_ca.pem"

# CA paths for remote PKI (downloaded from GCP Secret Manager)
REMOTE_KEYCLOAK_CA_PATH = "certificates/KEYCLOAK_TLS_CRT.pem"
REMOTE_REGISTRATION_CA_PATH = "certificates/REGISTRATION_SERVER_TLS_CERT.pem"

#CA paths for local PKI
LOCAL_SERVER_CA_PATH = "../../base-services/registration/pki/server-ca/ca.crt.pem"

TELEMETRY_SENDING_DURATION = 10
TELEMETRY_SENDING_INTERVAL = 2

def get_ca_paths(pki_strategy: str) -> tuple[str, str]:
    """Get the appropriate CA paths based on PKI strategy."""
    if pki_strategy == "remote":
        return REMOTE_KEYCLOAK_CA_PATH, REMOTE_REGISTRATION_CA_PATH
    else:
        # For local PKI, the server CA signs all server certificates
        return LOCAL_SERVER_CA_PATH, LOCAL_SERVER_CA_PATH


def register(
    uid: str,
    pki_strategy: str,
    client_key_path: str,
    client_certificate_path: str,
    registration_url: str,
    operational_path: str,
) -> tuple[str, str]:
    """Get operational certificate and URLs from registration server."""
    keycloak_ca_path, registration_ca_path = get_ca_paths(pki_strategy)

    print("Step 1: Generating operational key pair...")
    # Generate a new RSA key pair for operational use (matches Go client behavior)
    operational_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    operational_key_bytes = operational_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.TraditionalOpenSSL,
        encryption_algorithm=serialization.NoEncryption(),
    )

    # Save operational key to file
    operational_key_path = Path(operational_path) / OPERATIONAL_KEY_FILE
    operational_key_path.parent.mkdir(parents=True, exist_ok=True)
    operational_key_path.write_bytes(operational_key_bytes)
    print(f"  Saved operational key to {operational_key_path}")

    print("Step 2: Creating Certificate Signing Request (CSR) for operational certificate...")
    # Create CSR with operational key (not factory key)
    # Note: Use DirectoryString with UTF8String encoding to match Go client behavior
    # The registration server requires CN to be encoded as UTF8String
    cn_value = f"VIN:{uid} DEVICE:{uid}"

    # Use _UnvalidatedDirectoryString to force UTF8String encoding
    from cryptography.x509.name import _ASN1Type

    csr = x509.CertificateSigningRequestBuilder().subject_name(x509.Name([
        x509.NameAttribute(NameOID.COMMON_NAME, cn_value, _ASN1Type.UTF8String),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Device Manufacturer"),
    ])).sign(operational_key, hashes.SHA256())

    csr_bytes = csr.public_bytes(encoding=serialization.Encoding.PEM)

    # Save CSR for debugging
    operational_csr_path = Path(operational_path) / "operational.csr.pem"
    operational_csr_path.write_bytes(csr_bytes)
    print(f"  Saved CSR to {operational_csr_path} (for debugging)")

    print(f"Step 3: Sending CSR to registration server at {registration_url}...")
    try:
        response = requests.post(
            registration_url + "/registration",
            data=csr_bytes,
            headers={"Content-Type": "application/x-pem-file"},
            cert=(client_certificate_path, client_key_path),  # Use factory cert for mTLS auth
            verify=registration_ca_path,  # Verify server certificate
        )
    except RequestException as error:
        print(f"Error during registration: {error}")
        sys.exit(1)

    if response.status_code != 200:
        print("Error during registration: HTTP status code was not 200.")
        print(response.text)
        sys.exit(1)

    data = response.json()

    print("Step 4: Parsing operational certificate...")
    operational_certificate_path = Path(operational_path) / OPERATIONAL_CERTIFICATE_FILE
    operational_certificate_path.parent.mkdir(parents=True, exist_ok=True)
    operational_certificate_path.write_text(data["certificate"])
    print(f"  Saved operational certificate to {operational_certificate_path.name}")

    keycloak_ca_dest = Path(operational_path) / OPERATIONAL_KEYCLOAK_CA_FILE
    shutil.copy(keycloak_ca_path, keycloak_ca_dest)
    print(f"  Copied Keycloak CA to {keycloak_ca_dest}")

    print("Successfully registered and received operational certificate.")
    print(f"  Keycloak URL: {data['keycloak_url']}")
    print(f"  NATS URL: {data['nats_url']}")

    return data["keycloak_url"].replace(" ", ""), data["nats_url"]


def get_access_token(
    keycloak_server_url: str,
    operational_path: str,
) -> tuple[str, int]:
    """Get access token from Keycloak server."""

    print("Step 1: Configuring mTLS with operational certificate...")
    print(f"Step 2: Requesting JWT from Keycloak at {keycloak_server_url}...")
    try:
        keycloak = KeycloakOpenID(
            keycloak_server_url,
            client_id="car",
            realm_name="sdv-telemetry",
            cert=(
                str(Path(operational_path) / "certs" / OPERATIONAL_CERTIFICATE_FILE),
                str(Path(operational_path) / "certs" / OPERATIONAL_KEY_FILE),
            ),
            verify=str(Path(operational_path) / "certs" / "ca.crt.pem"),
        )

        token = keycloak.token(grant_type="client_credentials")
    except KeycloakError as error:
        print(f"Error during keycloak call: {error}")
        sys.exit(1)

    print("Successfully retrieved access token.")
    print(f"  Token expires in: {token['expires_in']} seconds")

    return token["access_token"], token["expires_in"]


# Base GPS position (Oxford, UK) — drifts slightly each reading to simulate movement
_BASE_LAT = 51.752022
_BASE_LON = -1.257677
_BASE_ALT = 72.0


async def send_telemetry(nc: NatsClient, uid: str, interval: int, index: int, count: int) -> None:
    """Send a single telemetry message matching the IoT device payload."""
    lat = _BASE_LAT + random.uniform(-0.001, 0.001) * index
    lon = _BASE_LON + random.uniform(-0.001, 0.001) * index
    alt = _BASE_ALT + random.uniform(-2.0, 2.0)

    message = telemetry.telemetry_message(
        uid,
        [
            telemetry.SensorReading(
                sensor="time_passed",
                value=str(index * interval) + " seconds",
                data_type=telemetry.DataType.DYNAMIC,
            ),
            telemetry.SensorReading(
                sensor="index",
                value=str(index),
                data_type=telemetry.DataType.STATIC,
            ),
            telemetry.SensorReading(
                sensor="test_key",
                value="test_value",
                data_type=telemetry.DataType.STATIC,
            ),
            telemetry.SensorReading(
                sensor="gps.latitude",
                value=f"{lat:.6f}",
                data_type=telemetry.DataType.DYNAMIC,
            ),
            telemetry.SensorReading(
                sensor="gps.longitude",
                value=f"{lon:.6f}",
                data_type=telemetry.DataType.DYNAMIC,
            ),
            telemetry.SensorReading(
                sensor="gps.altitude",
                value=f"{alt:.2f}",
                data_type=telemetry.DataType.DYNAMIC,
            ),
        ],
    )

    await nc.publish(f"telemetry.prod.bigtable.{uid}", message.SerializeToString())

    print(f"Telemetry published ({index + 1}/{count}): lat={lat:.6f} lon={lon:.6f} alt={alt:.2f}")


async def send_data(uid: str, interval: int, nats_server_url: str, access_token: str) -> None:
    """Send telemetry data to NATS."""
    # Send telemetry for a reasonable duration based on interval
    duration = interval * 6  # Send 6 messages total
    message_count = math.floor(duration / interval) + 1

    # Error handler to suppress verbose connection retry messages
    async def error_handler(e):
        # Only log actual errors, not connection retries
        pass

    print(f"Connecting to NATS at {nats_server_url}...")
    nc = await nats.connect(
        nats_server_url,
        token=access_token,
        error_cb=error_handler,
        connect_timeout=10,  # Increase timeout to reduce retry noise
        max_reconnect_attempts=3,
    )
    print(f"Connected. Sending {message_count} telemetry messages...")

    for index in range(message_count):
        if index != 0:
            await asyncio.sleep(interval)

        await send_telemetry(nc, uid, interval, index, message_count)

    await nc.close()

    print("Successfully sent test telemetry data.")
