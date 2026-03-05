import datetime
import os
from pathlib import Path
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import rsa

# Factory CA paths (local PKI)
_HERE = os.path.dirname(os.path.abspath(__file__))
LOCAL_FACTORY_CA_CERT = os.path.join(_HERE, "..", "..", "base-services", "registration", "pki", "factory-ca", "ca.crt.pem")
LOCAL_FACTORY_CA_KEY  = os.path.join(_HERE, "..", "..", "base-services", "registration", "pki", "factory-ca", "ca.key.pem")


def generate_factory_cert(uid: str, output_dir: str) -> tuple[str, str]:
    """
    Generate a factory certificate for a device (local PKI).

    Equivalent to generate-factory-cert.sh: creates an RSA key, signs a
    certificate with the local factory CA, and writes a chain file.

    Args:
        uid: unique device identifier
        output_dir: directory where the generated files are written

    Returns:
        Tuple of (chain_path, key_path)
    """
    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)
    prefix = out / f"vehicle-{uid}-factory"

    ca_cert_path = Path(LOCAL_FACTORY_CA_CERT)
    ca_key_path  = Path(LOCAL_FACTORY_CA_KEY)
    if not ca_cert_path.exists():
        raise FileNotFoundError(f"Factory CA certificate not found: {ca_cert_path}")
    if not ca_key_path.exists():
        raise FileNotFoundError(f"Factory CA key not found: {ca_key_path}")

    ca_cert = x509.load_pem_x509_certificate(ca_cert_path.read_bytes())
    ca_key  = serialization.load_pem_private_key(ca_key_path.read_bytes(), password=None)

    print("  Generating RSA private key...")
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    key_path = prefix.with_name(prefix.name + "-key.pem")
    key_path.write_bytes(private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.TraditionalOpenSSL,
        encryption_algorithm=serialization.NoEncryption(),
    ))

    print("  Signing certificate with factory CA...")
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(x509.Name([
            x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Vehicle Manufacturer"),
            x509.NameAttribute(NameOID.COMMON_NAME, f"VIN:{uid} DEVICE:{uid}"),
        ]))
        .issuer_name(ca_cert.subject)
        .public_key(private_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now)
        .not_valid_after(now + datetime.timedelta(days=365))
        .sign(ca_key, hashes.SHA256())
    )

    cert_pem = cert.public_bytes(serialization.Encoding.PEM)
    Path(prefix.with_name(prefix.name + ".pem")).write_bytes(cert_pem)

    print("  Building certificate chain...")
    chain_path = prefix.with_name(prefix.name + "-chain.pem")
    chain_path.write_bytes(cert_pem + b"\n" + ca_cert_path.read_bytes())

    print(f"  Key:   {key_path}")
    print(f"  Chain: {chain_path}")
    return str(chain_path), str(key_path)


