variable "environment" {
  type        = string
  description = "The environment where the infrastructure will be deployed"
  default     = ""
}

variable "region" {
  type        = string
  description = "The region in which to deploy the resources"
  default     = ""
}

variable "zone" {
  type        = string
  description = "The zone in which to deploy the resources"
  default     = ""
}

variable "project_id" {
  type        = string
  description = "The project id of your project in GCP"
  default     = ""
}

variable "repository" {
  type        = string
  description = "The URL of your (forked) repository"
  default     = ""
}

variable "random_suffix" {
  type        = string
  description = "A random suffix to ensure resource uniqueness"
}

variable "github_org" {
  type        = string
  description = "The ID of your Github organization"
  default     = ""
}

variable "pki_strategy" {
  description = "Strategy: 'local' or 'remote'"
  type        = string
  default     = "local"
}

variable "keycloak_hostname" {
  type        = string
  description = "The hostname for Keycloak service"
}

variable "nats_hostname" {
  type        = string
  description = "The hostname for NATS service"
}

variable "registration_hostname" {
  type        = string
  description = "The hostname for the registration server"
}

variable "base_domain" {
  type        = string
  description = "The base domain to append to hostnames"
}

variable "existing_dns_zone" {
  type        = string
  default     = ""
  description = "Name of existing Cloud DNS zone to use (leave empty to create new)"
}

variable "existing_server_ca" {
  type        = string
  default     = ""
  description = "Name of existing server CA to use (leave empty to create new)"
}

variable "existing_server_ca_pool" {
  type        = string
  default     = ""
  description = "Pool name of existing server CA (required if existing_server_ca is set)"
}

variable "existing_factory_ca" {
  type        = string
  default     = ""
  description = "Name of existing factory CA to use (leave empty to create new)"
}

variable "existing_factory_ca_pool" {
  type        = string
  default     = ""
  description = "Pool name of existing factory CA (required if existing_factory_ca is set)"
}

variable "existing_reg_ca" {
  type        = string
  default     = ""
  description = "Name of existing registration CA to use (leave empty to create new)"
}

variable "existing_reg_ca_pool" {
  type        = string
  default     = ""
  description = "Pool name of existing registration CA (required if existing_reg_ca is set)"
}

variable "wif_pool_id" {
  type        = string
  default     = ""
  description = "ID of Workload Identity Pool to be created for github"
}

variable "wif_provider_id" {
  type        = string
  default     = "github"
  description = "ID of Workload Identity Provider to be created for github"
}

variable "created_reg_ca_pool" {
  type        = string
  default     = ""
  description = "Pool name of fresh created registration CA (required if existing_reg_ca is NOT set)"
}

variable "created_server_ca_pool" {
  type        = string
  default     = ""
  description = "Pool name of fresh created server CA (required if existing_reg_ca is NOT set)"
}

variable "created_factory_ca_pool" {
  type        = string
  default     = ""
  description = "Pool name of fresh created factory CA (required if existing_reg_ca is NOT set)"
}
