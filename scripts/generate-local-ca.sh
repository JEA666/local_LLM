#!/usr/bin/env bash
set -euo pipefail

# Generates a private root CA + a leaf certificate for the given domain, and
# a real certs/Caddyfile from certs/Caddyfile.example. For domains that can
# never get a publicly-trusted certificate (a .home/.lan/etc that isn't
# publicly delegated -- see README.md "Custom domain + HTTPS"), this is the
# only way to get a real (not just click-through) trusted HTTPS setup: the
# CA cert (certs/ca.crt) needs installing as a trusted root on every device
# that should see a valid padlock, once per device.
#
# Usage: ./generate-local-ca.sh <domain> [ip-address]
# Example: ./generate-local-ca.sh llm.example.home 192.168.1.50

DOMAIN="${1:?Usage: generate-local-ca.sh <domain> [ip-address]}"
IP="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="$SCRIPT_DIR/../certs"
mkdir -p "$CERTS_DIR"
cd "$CERTS_DIR"

echo "=== Generating root CA ==="
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
  -subj "/CN=local-llm homelab CA/O=$DOMAIN" \
  -out ca.crt

echo "=== Generating leaf certificate for $DOMAIN ==="
cat > san.cnf <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $DOMAIN

[v3_req]
keyUsage = keyEncipherment, digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = $DOMAIN
EOF
if [[ -n "$IP" ]]; then
  echo "IP.1 = $IP" >> san.cnf
fi

openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr -config san.cnf
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 825 -sha256 -extfile san.cnf -extensions v3_req

echo "=== Generating Caddyfile for $DOMAIN ==="
sed "s/DOMAIN_PLACEHOLDER/$DOMAIN/g" Caddyfile.example > Caddyfile

echo "=== Generating portal/conf.yml for $DOMAIN ==="
sed "s/DOMAIN_PLACEHOLDER/$DOMAIN/g" "$SCRIPT_DIR/../portal/conf.yml.example" \
  > "$SCRIPT_DIR/../portal/conf.yml"

echo "=== Generating portal/docs/ for $DOMAIN ==="
echo "  (model name left as MODEL_NAME_PLACEHOLDER in api.html -- edit by hand"
echo "  to match your MODEL_FILE, this script only knows the domain)"
DOCS_DIR="$SCRIPT_DIR/../portal/docs"
for page in index api environment; do
  sed "s/DOMAIN_PLACEHOLDER/$DOMAIN/g" "$DOCS_DIR/$page.html.example" > "$DOCS_DIR/$page.html"
done

echo "=== Generating searxng/settings.yml for $DOMAIN ==="
SEARXNG_SECRET="$(openssl rand -hex 32)"
sed -e "s/DOMAIN_PLACEHOLDER/$DOMAIN/g" \
    -e "s/REPLACE_ME_WITH_YOUR_OWN_openssl_rand_hex_32/$SEARXNG_SECRET/g" \
  "$SCRIPT_DIR/../searxng/settings.yml.example" \
  > "$SCRIPT_DIR/../searxng/settings.yml"

echo ""
echo "Done."
echo "  CA to trust on client devices: $CERTS_DIR/ca.crt"
echo "  (also served at https://$DOMAIN/ca.crt once the stack is up -- see portal/docs/api.html)"
