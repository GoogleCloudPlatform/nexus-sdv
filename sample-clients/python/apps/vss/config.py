# config.py

# Netzwerk-Einstellungen
KUKSA_IP = '127.0.0.1'
KUKSA_PORT = 56789  # Dein gemappter Docker-Port

# Vehicle metadata (Nexus static column family)
VIN = "WMI-NEXUS-789"
VEHICLE_MODEL = "Nexus-SDV-Prototype-V1"

# VSS paths (COVESA standard)
PATH_SPEED = 'Vehicle.Speed'
PATH_BATTERY = 'Vehicle.Powertrain.Battery.StateOfCharge'

# Thresholds used by the logic
SPEED_THRESHOLD_CRITICAL = 120.0