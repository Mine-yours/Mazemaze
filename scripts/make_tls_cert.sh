#!/bin/bash
# 自己署名の TLS 証明書を一度だけ作る（.mazemaze_tls/、Git 管理外）。作り直すと、iPhone は再ペアリングが必要になる。
# 使い方: ./scripts/make_tls_cert.sh            （なければ作る）／ --fingerprint で SHA-256 指紋だけ表示
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=".mazemaze_tls"
if [ ! -s "$DIR/cert.pem" ] || [ ! -s "$DIR/key.pem" ]; then
  mkdir -p "$DIR"; chmod 700 "$DIR"
  cat > "$DIR/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = Mazemaze local server
[v3]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:mazemaze.local
EOF
  ( umask 077; openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -sha256 \
      -keyout "$DIR/key.pem" -out "$DIR/cert.pem" -config "$DIR/openssl.cnf" >/dev/null 2>&1 ) \
    || { echo "証明書を作成できませんでした（openssl が必要です）。" >&2; exit 1; }
  chmod 600 "$DIR/key.pem"
fi
# SHA-256 of the DER certificate, lowercase hex (what the iPhone app compares).
openssl x509 -in "$DIR/cert.pem" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f'
