# config.py

# Netzwerk-Einstellungen
KUKSA_IP = '127.0.0.1'
KUKSA_PORT = 56789  # Dein gemappter Docker-Port

# Fahrzeug-Metadaten (Nexus Static Column Family)
VIN = "WMI-NEXUS-789"
VEHICLE_MODEL = "Nexus-SDV-Prototype-V1"

# VSS Pfade (COVESA Standard)
PATH_SPEED = 'Vehicle.Speed'
PATH_BATTERY = 'Vehicle.Powertrain.Battery.StateOfCharge'

# Schwellenwerte für die Logik
SPEED_THRESHOLD_CRITICAL = 120.0