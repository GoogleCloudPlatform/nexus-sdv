import argparse


def parse_args():
    parser = argparse.ArgumentParser(
        description="Device client for SDV telemetry system"
    )
    parser.add_argument(
        "-uid",
        required=True,
        help="device identifier",
    )
    parser.add_argument(
        "-pki_strategy",
        required=True,
        choices=["local", "remote"],
        help="PKI strategy: 'local' or 'remote'",
    )
    parser.add_argument(
        "-factory-cert",
        required=True,
        help="Path to factory certificate chain (PEM)",
    )
    parser.add_argument(
        "-factory-key",
        required=True,
        help="Path to factory private key (PEM)",
    )
    parser.add_argument(
        "-registration-url",
        required=True,
        help="Registration server URL (e.g., https://registration.example.com:8080)",
    )
    parser.add_argument(
        "-interval",
        type=int,
        default=5,
        help="Telemetry interval in seconds (default: 5)",
    )
    return parser.parse_args()

def main():
    print("Hello from devices!")


if __name__ == "__main__":
    main()
