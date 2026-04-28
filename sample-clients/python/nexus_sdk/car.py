import sys
import math
import os
import nats
import asyncio
import requests
from . import telemetry
import time
import json
from pathlib import Path
from keycloak import KeycloakOpenID, KeycloakError
from requests.exceptions import RequestException
from nats.aio.client import Client as NATS
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization, hashes
from cryptography import x509
from cryptography.x509.oid import NameOID

# Variables
#VIN = "VEHICLE001"
#DEVICE = "car"

# Der feste Anker: Wo liegt dieses SDK?
SDK_DIR = Path(__file__).parent.absolute()
PROJECT_ROOT = SDK_DIR.parent

# try to manage the cert path hell
# beginning with "/", stay absolute. 
# otherwise, beginning with PROJECT_ROOT.
def resolve_path(p: str) -> str:
    path = Path(p)
    if path.is_absolute():
        return str(path)
    # Dies löst auch "../../" korrekt ab dem PROJECT_ROOT auf!
    return str((PROJECT_ROOT / path).resolve())

OPERATIONAL_CERTIFICATE_PATH = resolve_path("certificates/operational.crt.pem")
OPERATIONAL_KEY_PATH = resolve_path("certificates/operational.key.pem")

# CA paths for remote PKI (downloaded from GCP Secret Manager)
REMOTE_KEYCLOAK_CA_PATH = resolve_path("certificates/KEYCLOAK_TLS_CRT.pem")
REMOTE_REGISTRATION_CA_PATH = resolve_path("certificates/REGISTRATION_SERVER_TLS_CERT.pem")

#CA paths for local PKI
LOCAL_SERVER_CA_PATH = resolve_path("../../base-services/registration/pki/server-ca/ca.crt.pem")

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
    vin: str,
    pki_strategy: str,
    client_key_path: str,
    client_csr_path: str,
    client_certificate_path: str,
    registration_url: str,
) -> tuple[str, str, str]:
    """Static - Part Get operational certificate and URLs from registration server."""

    _, registration_ca_path = get_ca_paths(pki_strategy)

    print("Step 1: Generating operational key pair...")
    # Generate a new RSA key pair for operational use (matches Go client behavior)
    operational_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    operational_key_bytes = operational_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.TraditionalOpenSSL,
        encryption_algorithm=serialization.NoEncryption(),
    )

    # Save operational key to file
    operational_key_path = Path(OPERATIONAL_KEY_PATH)
    operational_key_path.parent.mkdir(parents=True, exist_ok=True)
    operational_key_path.write_bytes(operational_key_bytes)
    print(f"  Saved operational key to {OPERATIONAL_KEY_PATH}")

    print("Step 2: Creating Certificate Signing Request (CSR) for operational certificate...")
    # Create CSR with operational key (not factory key)
    # Note: Use DirectoryString with UTF8String encoding to match Go client behavior
    # The registration server requires CN to be encoded as UTF8String
    # DEVICE is set to VIN (matches factory cert and Go client behavior)
    cn_value = f"VIN:{vin} DEVICE:{vin}"

    # Use _UnvalidatedDirectoryString to force UTF8String encoding
    from cryptography.x509.name import _ASN1Type

    csr = x509.CertificateSigningRequestBuilder().subject_name(x509.Name([
        x509.NameAttribute(NameOID.COMMON_NAME, cn_value, _ASN1Type.UTF8String),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Vehicle Manufacturer"),
    ])).sign(operational_key, hashes.SHA256())

    csr_bytes = csr.public_bytes(encoding=serialization.Encoding.PEM)

    # Save CSR for debugging
    Path("certificates/operational.csr.pem").write_bytes(csr_bytes)
    print(f"  Saved CSR to certificates/operational.csr.pem (for debugging)")

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
    operational_certificate_path = Path(OPERATIONAL_CERTIFICATE_PATH)
    operational_certificate_path.parent.mkdir(parents=True, exist_ok=True)
    operational_certificate_path.write_text(data["certificate"])
    print(f"  Saved operational certificate to {OPERATIONAL_CERTIFICATE_PATH}")

    print("Successfully registered and received operational certificate.")
    print(f"  Keycloak URL: {data['keycloak_url']}")
    print(f"  NATS URL: {data['nats_url']}")

    return data["keycloak_url"].replace(" ", ""), data["nats_url"], OPERATIONAL_KEY_PATH


class NexusCar:
    def __init__(self, config_path="nexus_client_config.json"):
        self.config_path = config_path
        with open(config_path, "r") as f:
            self.config = json.load(f)
        self.nc = NATS()
        self._access_token = None
        self._token_expiry = 0

    async def get_access_token(self):
        """Requests JWT Token via Keycloak with mTLS and CA-Validation."""
        now = time.time()
        if not self._access_token or now >= self._token_expiry:
            print("[NexusCar] requesting fresh OIDC token...")
            
            # Wir brauchen den CA-Pfad aus der Config oder den globalen Variablen
            # Im Remote-Fall ist das meist REMOTE_KEYCLOAK_CA_PATH
            ca_path = self.config.get("keycloak_ca_path", REMOTE_KEYCLOAK_CA_PATH)

            try:
                # prepare JWT query
                keycloak_openid = KeycloakOpenID(
                    server_url=self.config["keycloak_url"],
                    client_id="car",
                    realm_name="sdv-telemetry", # Realm-Name!!!
                    # mTLS: Operative Zertifikate zur Identifikation des Fahrzeugs
                    cert=(
                        self.config["operational_cert_path"], 
                        self.config["operational_key_path"]
                    ),
                    # SSL-Verifikation: CA-Zertifikat zur Validierung des Servers
                    verify=ca_path
                )

                # Token-Abruf
                token_info = keycloak_openid.token(grant_type='client_credentials')
                
                self._access_token = token_info['access_token']
                self._token_expiry = now + token_info['expires_in'] - 60
                print("✅ Token received from Keycloak")
                
            except Exception as e:
                print(f"❌ Keycloak Error: {e}")
                raise

        return self._access_token

    async def send_telemetry_batch(self, readings_list):
        """Sending Protobuf-Batch to NATS."""
        
        # Verbindung herstellen, falls nicht vorhanden oder geschlossen
        if self.nc is None or not self.nc.is_connected:
            token = await self.get_access_token()
            print(f"Connecting NATS via {self.config['nats_url']}...")
            
            self.nc = await nats.connect(
                self.config["nats_url"],
                token=token,
                connect_timeout=10,
                max_reconnect_attempts=3,
                # Optional: error_cb=self._error_handler 
            )
            print("✅ NATS connection established.")

        vin = self.config["vin"]
        
        # 1. Protobuf Nachricht erstellen
        message = telemetry.telemetry_message(vin, readings_list)
        
        # 2. Nexus-Telemetry-Subject
        subject = f"telemetry.prod.bigtable.{vin}"
        
        # 3. Senden und Flushen
        await self.nc.publish(subject, message.SerializeToString())
        await self.nc.flush() 
        print(f"[NATS] Telemetry sent to {subject}")

    async def close(self):
        """Clean connection closing."""
        if self.nc and self.nc.is_connected:
            await self.nc.close()
            print("NATS connection closed.")