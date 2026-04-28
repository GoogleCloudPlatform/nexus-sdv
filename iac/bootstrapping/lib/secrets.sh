#!/bin/bash
# ==============================================================================
# Nexus SDV Bootstrapping — Shared Secret Library
#
# Sourced by all bootstrap and teardown scripts to avoid code duplication.
# ==============================================================================

add_secret() {
    local secret_name="$1"
    local secret_value="$2"

    local create_output
    create_output=$(gcloud secrets create "$secret_name" --labels="nexussdvenv=${ENV}" --replication-policy="automatic" --project="$GCP_PROJECT_ID" 2>&1) || {
        # This block runs ONLY if gcloud exits non-zero (creation failed)

        if ! echo "$create_output" | grep -q "already exists"; then
            # Error is NOT "already exists" → real problem (permissions, quota, etc.)
            log_error "Failed to create secret $secret_name: $create_output"
        fi
        # Error IS "already exists" → expected on re-runs, continue normally
    }
    echo -n "$secret_value" | gcloud secrets versions add "$secret_name" --data-file=- --project="$GCP_PROJECT_ID" --quiet
}

configure_secrets() {
    add_secret "KEYCLOAK_GCP_SERVICE_ACCOUNT" "keycloak-gsa@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
    add_secret "BIGTABLE_CONNECTOR_GCP_SERVICE_ACCOUNT" "bigtable-connector@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
    add_secret "DATA_API_BIGTABLE_CONNECTOR_GCP_SERVICE_ACCOUNT" "data-api-bigtable-connector@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
    add_secret "KEYCLOAK_DB_PASSWORD" "${KEYCLOAK_DB_PASSWORD}"
    add_secret "KEYCLOAK_ADMIN_PASSWORD" "$(openssl rand -base64 32)"
    # NATS credentials:
    # - NATS_SERVER_USER/PASSWORD: Main admin user with full NATS access (publish, subscribe, admin)
    # - NATS_AUTH_CALLOUT_PASSWORD: Service user for nats-auth-callout pod (basic auth, bypasses JWT)
    # - NATS_CONNECTOR_PASSWORD: Restricted user "connector" with read-only access to telemetry topics only (principle of least privilege)
    add_secret "NATS_SERVER_USER" "nats-user"
    add_secret "NATS_SERVER_PASSWORD" "$(openssl rand -hex 32)"
    add_secret "NATS_AUTH_CALLOUT_PASSWORD" "$(openssl rand -hex 32)"
    add_secret "NATS_CONNECTOR_PASSWORD" "$(openssl rand -hex 32)"
    add_secret "KEYCLOAK_INSTANCE_CON_SQL_PROXY" "${GCP_PROJECT_ID}:${GCP_REGION}:cloud-sql-${ENV}"
    add_secret "IMAGE_REPO" "${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/artifact-registry"

    NKEY_OUT=$(nk -gen account -pubout)
    add_secret "JWT_ACC_SIGNING_KEY" "$(echo "$NKEY_OUT" | sed -n '1p')"
    add_secret "NATS_AUTH_CALLOUT_NKEY_PUB" "$(echo "$NKEY_OUT" | sed -n '2p')"

    # --- b) Global Context & Build Variables (NEU) ---
    log_info "Storing Global Context Variables..."
    add_secret "DEPLOY_MODE" "$DEPLOY_MODE"

    if [ "$DEPLOY_MODE" == "cloudbuild" ]; then
        add_secret "GCP_PROJECT_ID" "$GCP_PROJECT_ID"
        add_secret "GCP_REGION" "$GCP_REGION"
        add_secret "ENV" "$ENV"
        add_secret "PKI_STRATEGY" "$PKI_STRATEGY"

        # GKE Context
        add_secret "GKE_CLUSTER_NAME" "${ENV}-gke"
    fi

    # --- c) DNS, BASE_DOMAIN & PKI Configuration (Remote only) ---
    if [ "$PKI_STRATEGY" == "remote" ]; then
        add_secret "BASE_DOMAIN" "$BASE_DOMAIN"

        # Store CA pool names and CA names in Secret Manager for workflows to use
        SERVER_CA_POOL_NAME="${EXISTING_SERVER_CA_POOL:-$CREATED_SERVER_CA_POOL}"
        FACTORY_CA_POOL_NAME="${EXISTING_FACTORY_CA_POOL:-$CREATED_FACTORY_CA_POOL}"
        SERVER_CA_NAME="${EXISTING_SERVER_CA:-server-ca}"
        FACTORY_CA_NAME="${EXISTING_FACTORY_CA:-factory-ca}"

        add_secret "SERVER_CA_POOL" "$SERVER_CA_POOL_NAME"
        add_secret "FACTORY_CA_POOL" "$FACTORY_CA_POOL_NAME"
        add_secret "SERVER_CA" "$SERVER_CA_NAME"
        add_secret "FACTORY_CA" "$FACTORY_CA_NAME"

        # Store hostnames
        add_secret "KEYCLOAK_HOSTNAME" "$KEYCLOAK_HOSTNAME"
        add_secret "NATS_HOSTNAME" "$NATS_HOSTNAME"
        add_secret "REGISTRATION_HOSTNAME" "$REGISTRATION_HOSTNAME"

        log_info "Stored PKI configuration in Secret Manager:"
        log_info "  SERVER_CA_POOL: $SERVER_CA_POOL_NAME"
        log_info "  SERVER_CA: $SERVER_CA_NAME"
        log_info "  FACTORY_CA_POOL: $FACTORY_CA_POOL_NAME"
        log_info "  FACTORY_CA: $FACTORY_CA_NAME"

        log_info "Checking Cloud DNS configuration..."
        cd iac/terraform
        NAME_SERVERS=$(terraform output -json name_servers | jq -r '.[]')
        cd ../..

        if [ -n "$NAME_SERVERS" ]; then
            log_info "Cloud DNS Zone '${BASE_DOMAIN}' is managed by Terraform."
            log_warn ">>> ACTION REQUIRED: Update your Domain Registrar with these Nameservers: <<<"
            log_info "$NAME_SERVERS"
            log_warn ">>> -------------------------------------------------------------------- <<<"
        fi
    fi
}


generate_local_ca() {
    local ca_name="$1"
    local common_name="$2"
    local pki_dir="$3"
    local template_file="iac/bootstrapping/templates/openssl_ca.conf.tpl"
    local ca_dir="$pki_dir/$ca_name"
    local conf_file="$ca_dir/ca.conf"

    sed "s/%%COMMON_NAME%%/$common_name/" "$template_file" > "$conf_file"

    openssl req -x509 -newkey rsa:4096 -days 3650 -nodes \
        -keyout "$ca_dir/ca.key.pem" -out "$ca_dir/ca.crt.pem" \
        -config "$conf_file"
}

generate_local_server_cert() {
    local service_name="$1"
    local sans="$2"
    local pki_dir="$3"
    local template_file="iac/bootstrapping/templates/openssl_server.ext.tpl"
    local server_ca_dir="$pki_dir/server-ca"
    local service_dir="$server_ca_dir/$service_name"
    local ext_file="$service_dir/$service_name.ext"

    sed "s/%%SANS%%/$sans/" "$template_file" > "$ext_file"

    openssl req -new -newkey rsa:2048 -nodes \
        -keyout "$service_dir/$service_name.key.pem" \
        -out "$service_dir/$service_name.csr.pem" -subj "/CN=127.0.0.1"

    openssl x509 -req -days 730 -in "$service_dir/$service_name.csr.pem" \
        -CA "$server_ca_dir/ca.crt.pem" -CAkey "$server_ca_dir/ca.key.pem" -CAcreateserial \
        -out "$service_dir/$service_name.crt.pem" \
        -extfile "$ext_file"
}

download_remote_ca() {
    local ca_type="$1"
    local existing_ca="$2"
    local existing_ca_pool="$3"
    local created_ca_pool="$4"
    local pki_dir="$5"

    if [ -n "$existing_ca" ]; then
        log_info "Using existing $ca_type CA: $existing_ca from pool $existing_ca_pool"
        gcloud privateca roots describe "$existing_ca" \
            --pool="$existing_ca_pool" \
            --location="$GCP_REGION" \
            --format="value(pemCaCertificates)" > "$pki_dir/$ca_type-ca/ca.crt.pem"
    else
        log_info "Using newly created $ca_type CA from $ca_type-ca-pool"
        gcloud privateca roots list --pool="$created_ca_pool" --location="$GCP_REGION" --format="value(pemCaCertificates)" --limit=1 > "$pki_dir/$ca_type-ca/ca.crt.pem"
    fi
}

initialize_pki_local() {
    log_info "Generating Local CAs..."
    generate_local_ca "factory-ca" "Nexus Factory CA (Local)" "$PKI_DIR"
    generate_local_ca "server-ca" "Nexus Server CA (Local)" "$PKI_DIR"
    generate_local_ca "registration-ca" "Nexus Registration CA (Local)" "$PKI_DIR"

    log_info "Generating Local Server Certificates..."
    generate_local_server_cert "keycloak" "IP.1 = 127.0.0.1\nDNS.1 = localhost\nDNS.2 = keycloak" "$PKI_DIR"
    generate_local_server_cert "registration" "IP.1 = 127.0.0.1\nDNS.1 = localhost\nDNS.2 = registration" "$PKI_DIR"
}

initialize_pki_remote() {
    log_info "Downloading Remote CAs..."
    download_remote_ca "server" "$EXISTING_SERVER_CA" "$EXISTING_SERVER_CA_POOL" "$CREATED_SERVER_CA_POOL" "$PKI_DIR"
    download_remote_ca "factory" "$EXISTING_FACTORY_CA" "$EXISTING_FACTORY_CA_POOL" "$CREATED_FACTORY_CA_POOL" "$PKI_DIR"

    log_info "Checking for local Registration CA..."
    if [ ! -f "$PKI_DIR/registration-ca/ca.key.pem" ] || [ ! -f "$PKI_DIR/registration-ca/ca.crt.pem" ]; then
        log_info "Generating new local Registration CA..."
        openssl genrsa -out "$PKI_DIR/registration-ca/ca.key.pem" 4096
        openssl req -new -x509 -days 3650 -key "$PKI_DIR/registration-ca/ca.key.pem" \
          -out "$PKI_DIR/registration-ca/ca.crt.pem" \
          -subj "/C=US/ST=State/L=City/O=SDV/OU=Registration/CN=Registration CA"
        log_info "${CHECK} Local Registration CA generated"
    else
        log_info "${CHECK} Local Registration CA already exists"
    fi

    log_info "Pre-generating Client Cert via Google CAS (Remote)..."
    openssl genpkey -algorithm RSA -out "$PYTHON_CERTS_DIR/client.key.pem"
    openssl req -new -key "$PYTHON_CERTS_DIR/client.key.pem" \
        -out "$PYTHON_CERTS_DIR/client.csr.pem" \
        -subj "/CN=VIN:12345678901234567 DEVICE:car/O=Valtech Mobility GmbH"
    gcloud privateca certificates create "car-$(date +%s)" \
        --issuer-pool="${EXISTING_FACTORY_CA_POOL:-$CREATED_FACTORY_CA_POOL}" --issuer-location="$GCP_REGION" \
        --csr="$PYTHON_CERTS_DIR/client.csr.pem" \
        --cert-output-file="$PYTHON_CERTS_DIR/client.crt.pem" \
        --validity="P30D" --quiet
    log_info "Client Certificate placed in $PYTHON_CERTS_DIR"

    touch "$PKI_DIR/server-ca/keycloak/keycloak.crt.pem"
    touch "$PKI_DIR/server-ca/keycloak/keycloak.key.pem"

    if [ -z "$EXISTING_SERVER_CA" ]; then
        log_info "Saving created CA pools to $ENV_FILE for future runs..."
        sed_inplace "s|^EXISTING_SERVER_CA=.*|EXISTING_SERVER_CA=\"server-root-ca\"|" "$ENV_FILE"
        sed_inplace "s|^EXISTING_SERVER_CA_POOL=.*|EXISTING_SERVER_CA_POOL=\"${CREATED_SERVER_CA_POOL}\"|" "$ENV_FILE"
        sed_inplace "s|^EXISTING_FACTORY_CA=.*|EXISTING_FACTORY_CA=\"factory-root-ca\"|" "$ENV_FILE"
        sed_inplace "s|^EXISTING_FACTORY_CA_POOL=.*|EXISTING_FACTORY_CA_POOL=\"${CREATED_FACTORY_CA_POOL}\"|" "$ENV_FILE"
        sed_inplace "s|^EXISTING_REG_CA=.*|EXISTING_REG_CA=\"registration-root-ca\"|" "$ENV_FILE"
        sed_inplace "s|^EXISTING_REG_CA_POOL=.*|EXISTING_REG_CA_POOL=\"${CREATED_REG_CA_POOL}\"|" "$ENV_FILE"
        log_info "${CHECK} CA configuration saved for reuse"
    fi
}


initialize_pki() {
    log_info "Initializing PKI ($PKI_STRATEGY)..."
    PKI_DIR="./base-services/registration/pki"
    PYTHON_CERTS_DIR="./base-services/registration/python/certificates"

    rm -rf "$PKI_DIR/server-ca" "$PKI_DIR/factory-ca" "$PKI_DIR/registration-ca"
    mkdir -p "$PKI_DIR/server-ca/keycloak" "$PKI_DIR/server-ca/registration" \
             "$PKI_DIR/factory-ca" "$PKI_DIR/registration-ca" \
             "$PYTHON_CERTS_DIR"

    if [ "$PKI_STRATEGY" == "local" ]; then
        # --- Step 11a: Initialize PKI in local mode
        initialize_pki_local
    else
        # --- Step 11b: Initialize PKI in remote mode
        initialize_pki_remote
    fi
}

upload_pki_secrets() {
    # Only upload Keycloak TLS secrets in local mode (they're empty in remote mode)
    if [ "$PKI_STRATEGY" == "local" ]; then
        log_info "Uploading Initial TLS Secrets..."
        add_secret "KEYCLOAK_TLS_CRT" "$(cat $PKI_DIR/server-ca/keycloak/keycloak.crt.pem)"
        add_secret "KEYCLOAK_TLS_KEY" "$(cat $PKI_DIR/server-ca/keycloak/keycloak.key.pem)"
    else
        log_info "Skipping Keycloak TLS secret upload (will be generated by pipeline in remote mode)..."
    fi

    # Upload Registration CA Certificates
    log_info "Uploading Registration CA certificates to Secret Manager..."

    if [ "$PKI_STRATEGY" == "local" ]; then
        # LOCAL mode: Upload all CA certs and keys (server certs generated by workflow after deployment)
        add_secret "SERVER_CA_CERT" "$(cat $PKI_DIR/server-ca/ca.crt.pem)"
        add_secret "SERVER_CA_KEY" "$(cat $PKI_DIR/server-ca/ca.key.pem)"
        add_secret "REGISTRATION_CA_CERT" "$(cat $PKI_DIR/registration-ca/ca.crt.pem)"
        add_secret "REGISTRATION_CA_KEY" "$(cat $PKI_DIR/registration-ca/ca.key.pem)"
        add_secret "REGISTRATION_FACTORY_CA_CERT" "$(cat $PKI_DIR/factory-ca/ca.crt.pem)"
        log_info "${CHECK} All CA certificates and keys uploaded to Secret Manager (LOCAL mode)"
        log_info "  Note: Server certificates (registration, keycloak) will be generated by GitHub Actions workflows after deployment"
    else
        # REMOTE mode: Skip server certs (generated by pipeline), upload CA certs and Registration CA key
        add_secret "REGISTRATION_CA_CERT" "$(cat $PKI_DIR/registration-ca/ca.crt.pem)"
        add_secret "REGISTRATION_CA_KEY" "$(cat $PKI_DIR/registration-ca/ca.key.pem)"
        add_secret "REGISTRATION_FACTORY_CA_CERT" "$(cat $PKI_DIR/factory-ca/ca.crt.pem)"
        log_info "${CHECK} CA certificates uploaded (REMOTE mode)"
        log_info "${CHECK} Registration CA key uploaded (for signing vehicle operational certs)"
        log_info "  Note: Server certificates will be generated by GitHub Actions pipeline"
    fi
}

delete_gcp_secrets() {

    # List of all secrets created by bootstrap-platform-ca.sh
    SECRETS_TO_DELETE=(
        # Infrastructure secrets (always created)
        "GCP_REGION"
        "DEPLOY_MODE"
        "GCP_PROJECT_ID"
        "KEYCLOAK_GCP_SERVICE_ACCOUNT"
        "BIGTABLE_CONNECTOR_GCP_SERVICE_ACCOUNT"
        "DATA_API_BIGTABLE_CONNECTOR_GCP_SERVICE_ACCOUNT"
        "KEYCLOAK_DB_PASSWORD"
        "KEYCLOAK_ADMIN_PASSWORD"
        "NATS_SERVER_USER"
        "NATS_SERVER_PASSWORD"
        "NATS_AUTH_CALLOUT_PASSWORD"  # Service user for nats-auth-callout pod
        "NATS_CONNECTOR_PASSWORD"  # Restricted connector user for BigTable connector (read-only telemetry access)
        "KEYCLOAK_INSTANCE_CON_SQL_PROXY"
        "IMAGE_REPO"
        "JWT_ACC_SIGNING_KEY"
        "NATS_AUTH_CALLOUT_NKEY_PUB"
        "${ENV}-keycloak-hostname"
        "${ENV}-nats-hostname"
        "${ENV}-registration-hostname"

        # PKI secrets (always created)
        "REGISTRATION_CA_CERT"
        "REGISTRATION_CA_KEY"
        "REGISTRATION_FACTORY_CA_CERT"

        # Remote mode secrets (may not exist in local mode)
        "BASE_DOMAIN"
        "SERVER_CA_POOL"
        "FACTORY_CA_POOL"
        "SERVER_CA"
        "FACTORY_CA"
        "KEYCLOAK_HOSTNAME"
        "NATS_HOSTNAME"
        "REGISTRATION_HOSTNAME"

        # Cloud Build mode dependent secrets (may not exist in GitHub Actions mode)
        "GKE_CLUSTER_NAME"
        "ENV"
        "PKI_STRATEGY"

        # Local mode secrets (may not exist in remote mode)
        "KEYCLOAK_TLS_CRT"
        "KEYCLOAK_TLS_KEY"
        "SERVER_CA_CERT"
        "SERVER_CA_KEY"

        # Server certificates (created by workflows)
        "REGISTRATION_SERVER_TLS_CERT"
        "REGISTRATION_SERVER_TLS_KEY"

        "KEYCLOAK_JWK_URI"
        "KEYCLOAK_JWK_B64"
    )

    log_info "Deleting ${#SECRETS_TO_DELETE[@]} secrets..."

    for secret in "${SECRETS_TO_DELETE[@]}"; do
        if gcloud secrets describe "$secret" --project="$GCP_PROJECT_ID" &>/dev/null; then
            log_info "  - Deleting secret: $secret"
            gcloud secrets delete "$secret" --project="$GCP_PROJECT_ID" --quiet || log_info "    Failed to delete $secret"
        else
            log_info "  - Secret '$secret' not found (already deleted or never created)"
        fi
    done

    log_info "Secret Manager cleanup complete."
    echo ""
}
