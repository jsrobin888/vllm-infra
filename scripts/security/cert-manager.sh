#!/bin/bash
# =============================================================================
# Certificate Manager — TLS Cert Generation & Renewal
# Phase 46: TLS/Certificate Management — Stages 131-134
# =============================================================================
# Manages self-signed and Let's Encrypt TLS certificates for HAProxy.
# =============================================================================
set -euo pipefail

CERT_DIR="/etc/haproxy/certs"
DOMAIN="${DOMAIN:-vllm.internal}"
DAYS="${CERT_DAYS:-365}"

usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  generate-self-signed   Generate a self-signed certificate"
    echo "  generate-ca            Generate a CA + signed certificate"
    echo "  show                   Display certificate details"
    echo "  check-expiry           Check certificate expiry"
    echo "  renew                  Renew certificate (self-signed)"
    exit 1
}

generate_self_signed() {
    echo "Generating self-signed certificate for: ${DOMAIN}"
    mkdir -p "$CERT_DIR"

    openssl req -x509 -nodes \
        -days "$DAYS" \
        -newkey rsa:2048 \
        -keyout "${CERT_DIR}/${DOMAIN}.key" \
        -out "${CERT_DIR}/${DOMAIN}.crt" \
        -subj "/C=US/ST=CA/L=SanFrancisco/O=InfraTeam/CN=${DOMAIN}" \
        -addext "subjectAltName=DNS:${DOMAIN},DNS:*.${DOMAIN}"

    # HAProxy needs combined PEM
    cat "${CERT_DIR}/${DOMAIN}.crt" "${CERT_DIR}/${DOMAIN}.key" > "${CERT_DIR}/${DOMAIN}.pem"
    chmod 600 "${CERT_DIR}/${DOMAIN}.pem"

    echo "Certificate generated:"
    echo "  Cert:     ${CERT_DIR}/${DOMAIN}.crt"
    echo "  Key:      ${CERT_DIR}/${DOMAIN}.key"
    echo "  Combined: ${CERT_DIR}/${DOMAIN}.pem (for HAProxy)"
    echo "  Expires:  $(openssl x509 -in "${CERT_DIR}/${DOMAIN}.crt" -noout -enddate)"
}

generate_ca() {
    echo "Generating CA and signed certificate for: ${DOMAIN}"
    mkdir -p "$CERT_DIR"

    # Generate CA
    openssl genrsa -out "${CERT_DIR}/ca.key" 4096
    openssl req -x509 -new -nodes \
        -key "${CERT_DIR}/ca.key" \
        -sha256 -days 3650 \
        -out "${CERT_DIR}/ca.crt" \
        -subj "/C=US/ST=CA/L=SanFrancisco/O=InfraTeam/CN=vLLM Internal CA"

    # Generate server cert
    openssl genrsa -out "${CERT_DIR}/${DOMAIN}.key" 2048
    openssl req -new \
        -key "${CERT_DIR}/${DOMAIN}.key" \
        -out "${CERT_DIR}/${DOMAIN}.csr" \
        -subj "/C=US/ST=CA/L=SanFrancisco/O=InfraTeam/CN=${DOMAIN}"

    # Sign with CA
    cat > "${CERT_DIR}/ext.cnf" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = DNS:${DOMAIN}, DNS:*.${DOMAIN}
EOF

    openssl x509 -req \
        -in "${CERT_DIR}/${DOMAIN}.csr" \
        -CA "${CERT_DIR}/ca.crt" \
        -CAkey "${CERT_DIR}/ca.key" \
        -CAcreateserial \
        -out "${CERT_DIR}/${DOMAIN}.crt" \
        -days "$DAYS" \
        -sha256 \
        -extfile "${CERT_DIR}/ext.cnf"

    # HAProxy combined PEM (cert + key + ca)
    cat "${CERT_DIR}/${DOMAIN}.crt" "${CERT_DIR}/${DOMAIN}.key" "${CERT_DIR}/ca.crt" \
        > "${CERT_DIR}/${DOMAIN}.pem"
    chmod 600 "${CERT_DIR}/${DOMAIN}.pem"

    # Cleanup
    rm -f "${CERT_DIR}/${DOMAIN}.csr" "${CERT_DIR}/ext.cnf"

    echo "CA + Certificate generated:"
    echo "  CA Cert:  ${CERT_DIR}/ca.crt"
    echo "  Cert:     ${CERT_DIR}/${DOMAIN}.crt"
    echo "  Combined: ${CERT_DIR}/${DOMAIN}.pem"
}

show_cert() {
    if [[ -f "${CERT_DIR}/${DOMAIN}.crt" ]]; then
        openssl x509 -in "${CERT_DIR}/${DOMAIN}.crt" -noout -text | head -30
    else
        echo "No certificate found at ${CERT_DIR}/${DOMAIN}.crt"
        exit 1
    fi
}

check_expiry() {
    if [[ -f "${CERT_DIR}/${DOMAIN}.crt" ]]; then
        EXPIRY=$(openssl x509 -in "${CERT_DIR}/${DOMAIN}.crt" -noout -enddate | cut -d= -f2)
        EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$EXPIRY" +%s 2>/dev/null)
        NOW_EPOCH=$(date +%s)
        DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))

        echo "Certificate: ${CERT_DIR}/${DOMAIN}.crt"
        echo "Expires:     ${EXPIRY}"
        echo "Days left:   ${DAYS_LEFT}"

        if [[ $DAYS_LEFT -lt 30 ]]; then
            echo "[WARNING] Certificate expires in less than 30 days!"
            exit 1
        elif [[ $DAYS_LEFT -lt 7 ]]; then
            echo "[CRITICAL] Certificate expires in less than 7 days!"
            exit 2
        fi
    else
        echo "No certificate found"
        exit 1
    fi
}

renew_cert() {
    echo "Renewing self-signed certificate..."
    generate_self_signed
    echo ""
    echo "Reload HAProxy to apply:"
    echo "  systemctl reload haproxy"
}

case "${1:-}" in
    generate-self-signed) generate_self_signed ;;
    generate-ca) generate_ca ;;
    show) show_cert ;;
    check-expiry) check_expiry ;;
    renew) renew_cert ;;
    *) usage ;;
esac
