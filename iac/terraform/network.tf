resource "google_compute_network" "vpc" {
  name                    = "${var.environment}-vpc"
  auto_create_subnetworks = false
  depends_on = [google_project_service.project_apis]
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.environment}-subnet"
  ip_cidr_range = "10.0.0.0/16"
  region        = var.region
  network       = google_compute_network.vpc.id
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.10.0.0/16"
  }
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.20.0.0/16"
  }
}

resource "google_compute_global_address" "psc_range" {
  name          = "psc-peering"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.vpc.id

  address       = "10.100.0.0"
}

resource "google_service_networking_connection" "psc_connection" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psc_range.name]
}

resource "google_compute_firewall" "internet" {
  name = "internet-outbound"
  # Use .name instead of .id for firewall network reference
  # The .id format (projects/{{project}}/global/networks/{{name}}) causes API validation errors
  # The firewall resource expects either a simple network name or a full self_link URL
  network = google_compute_network.vpc.name

  allow {
    protocol = "all"
  }

  direction = "EGRESS"

  source_ranges      = [google_compute_subnetwork.subnet.ip_cidr_range, google_compute_subnetwork.subnet.secondary_ip_range[0].ip_cidr_range, google_compute_subnetwork.subnet.secondary_ip_range[1].ip_cidr_range]
  destination_ranges = ["0.0.0.0/0"]
}

resource "google_compute_router" "router" {
  name    = "router"
  region  = google_compute_subnetwork.subnet.region
  network = google_compute_network.vpc.id

  bgp {
    asn = 64514
  }
}

resource "google_compute_router_nat" "nat" {
  name                               = "nat"
  router                             = google_compute_router.router.name
  region                             = google_compute_router.router.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
