#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

###############################################################################
# Autheo Mainnet Full Node Installation Script
#
# OS:
#   Linux x86_64
#
# Components:
#   Go 1.23.1
#   Autheo Chain Core
#   Autheo Mainnet
#   systemd
#
# User/Group:
#   autheo:autheo
#
# Installation:
#   /usr/local/bin/autheod
#   /data/.autheo
#   /home/autheo/.autheo -> /data/.autheo
#   /root/.autheo -> /data/.autheo
#
# Service:
#   autheod.service
###############################################################################

############################
# Configuration
############################

GO_VERSION="1.23.1"
GO_ARCHIVE="go${GO_VERSION}.linux-amd64.tar.gz"
GO_URL="https://go.dev/dl/${GO_ARCHIVE}"
GO_SHA256_URL="https://dl.google.com/go/${GO_ARCHIVE}.sha256"

AUTHEO_USER="autheo"
AUTHEO_GROUP="autheo"

AUTHEO_REPO="https://github.com/autheo-blockchain/autheo-chain-core.git"
NETWORK_REPO="https://github.com/autheo-blockchain/networks.git"

AUTHEO_HOME="/data/.autheo"
AUTHEO_ROOT_LINK="/root/.autheo"

CHAIN_ID="autheo_2127-1"
NODE_NAME="new-node"

AUTHEO_BINARY="/usr/local/bin/autheod"
SERVICE_FILE="/etc/systemd/system/autheod.service"

BUILD_DIR="/tmp/autheo-chain-core"
NETWORK_DIR="/tmp/autheo-networks"

MINIMUM_GAS_PRICES="10000000000000aauth"
JSON_RPC_ADDRESS="0.0.0.0:8545"

############################
# Logging
############################

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
    printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
    exit 1
}

trap 'die "Command failed at line ${LINENO}: ${BASH_COMMAND}"' ERR

############################
# Root check
############################

if [[ "${EUID}" -ne 0 ]]; then
    die "This script must be run as root."
fi

############################
# OS / Architecture check
############################

ARCH="$(uname -m)"

if [[ "${ARCH}" != "x86_64" ]]; then
    die "Unsupported architecture: ${ARCH}. This script requires x86_64."
fi

if [[ ! -f /etc/os-release ]]; then
    die "/etc/os-release not found. Cannot verify Linux distribution."
fi

. /etc/os-release

log "Detected OS: ${PRETTY_NAME}"
log "Detected architecture: ${ARCH}"

############################
# Create System User & Group
############################

log "Setting up system group and user..."

if ! getent group "${AUTHEO_GROUP}" >/dev/null 2>&1; then
    groupadd --system "${AUTHEO_GROUP}"
    log "Created group: ${AUTHEO_GROUP}"
fi

if ! id -u "${AUTHEO_USER}" >/dev/null 2>&1; then
    useradd --system \
        --gid "${AUTHEO_GROUP}" \
        --create-home \
        --home-dir "/home/${AUTHEO_USER}" \
        --shell /bin/false \
        "${AUTHEO_USER}"
    log "Created user: ${AUTHEO_USER}"
fi

AUTHEO_USER_HOME="/home/${AUTHEO_USER}"
AUTHEO_USER_LINK="${AUTHEO_USER_HOME}/.autheo"

############################
# Required packages
############################

log "Installing required packages..."

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
    ca-certificates \
    curl \
    git \
    make \
    build-essential \
    tar \
    gzip

############################
# Install Go
############################

install_go() {

    if command -v go >/dev/null 2>&1; then
        CURRENT_GO="$(go version | awk '{print $3}' | sed 's/^go//')"

        if [[ "${CURRENT_GO}" == "${GO_VERSION}" ]]; then
            log "Go ${GO_VERSION} is already installed."
            return
        fi

        log "Existing Go version: ${CURRENT_GO}"
        log "Installing required Go version: ${GO_VERSION}"
    else
        log "Go is not installed. Installing Go ${GO_VERSION}..."
    fi

    TMP_DIR="$(mktemp -d)"

    cleanup_go() {
        cd /root
        rm -rf "${TMP_DIR}"
    }

    trap cleanup_go RETURN

    cd "${TMP_DIR}"

    log "Downloading ${GO_URL}"

    curl -fL --retry 3 --retry-delay 2 \
        -o "${GO_ARCHIVE}" \
        "${GO_URL}"

    log "Downloading Go checksum..."

    curl -fL --retry 3 --retry-delay 2 \
        -o "${GO_ARCHIVE}.sha256" \
        "${GO_SHA256_URL}"

    log "Verifying Go archive checksum..."

    ACTUAL_HASH="$(sha256sum "${GO_ARCHIVE}" | awk '{print $1}')"
    EXPECTED_HASH="$(tr -d ' \n\r' < "${GO_ARCHIVE}.sha256")"

    if [[ "${ACTUAL_HASH}" != "${EXPECTED_HASH}" ]]; then
        die "Checksum mismatch! Expected: ${EXPECTED_HASH}, Got: ${ACTUAL_HASH}"
    fi

    log "Checksum verified successfully."

    log "Removing previous /usr/local/go..."

    rm -rf /usr/local/go

    log "Extracting Go..."

    tar -C /usr/local -xzf "${GO_ARCHIVE}"

    if [[ ! -x /usr/local/go/bin/go ]]; then
        die "Go installation failed. /usr/local/go/bin/go not found."
    fi

    log "Go ${GO_VERSION} installed successfully."
}

install_go

export PATH="/usr/local/go/bin:${PATH}"

############################
# Persistent Go PATH
############################

cat > /etc/profile.d/go.sh <<'EOF'
export PATH=/usr/local/go/bin:$PATH
EOF

chmod 0644 /etc/profile.d/go.sh

if ! grep -qF 'export PATH=/usr/local/go/bin:$PATH' /root/.bashrc 2>/dev/null; then
    printf '\nexport PATH=/usr/local/go/bin:$PATH\n' >> /root/.bashrc
fi

log "Go version:"
/usr/local/go/bin/go version

############################
# Prepare Autheo directories
############################

log "Preparing Autheo data directory..."

mkdir -p "${AUTHEO_HOME}"
chown -R "${AUTHEO_USER}:${AUTHEO_GROUP}" "${AUTHEO_HOME}"
chmod 0700 "${AUTHEO_HOME}"

############################
# Create Symlinks
############################

# Create symlink for autheo user home
if [[ ! -L "${AUTHEO_USER_LINK}" ]] && [[ ! -e "${AUTHEO_USER_LINK}" ]]; then
    ln -s "${AUTHEO_HOME}" "${AUTHEO_USER_LINK}"
    chown -h "${AUTHEO_USER}:${AUTHEO_GROUP}" "${AUTHEO_USER_LINK}"
fi

# Create symlink for root
if [[ -L "${AUTHEO_ROOT_LINK}" ]]; then
    CURRENT_TARGET="$(readlink -f "${AUTHEO_ROOT_LINK}")"
    if [[ "${CURRENT_TARGET}" != "${AUTHEO_HOME}" ]]; then
        die "${AUTHEO_ROOT_LINK} exists but points to ${CURRENT_TARGET}, not ${AUTHEO_HOME}."
    fi
elif [[ -e "${AUTHEO_ROOT_LINK}" ]]; then
    die "${AUTHEO_ROOT_LINK} already exists and is not the expected symlink."
else
    ln -s "${AUTHEO_HOME}" "${AUTHEO_ROOT_LINK}"
fi

log "Autheo home: $(readlink -f "${AUTHEO_ROOT_LINK}")"

############################
# Clone / update Autheo source
############################

log "Preparing Autheo source..."

rm -rf "${BUILD_DIR}"

git clone --depth 1 "${AUTHEO_REPO}" "${BUILD_DIR}"

cd "${BUILD_DIR}"

############################
# Build autheod
############################

log "Building autheod..."

make build

if [[ ! -x "${BUILD_DIR}/build/autheod" ]]; then
    die "Build completed but ${BUILD_DIR}/build/autheod was not created."
fi

log "Checking generated autheod binary..."

"${BUILD_DIR}/build/autheod" version

############################
# Install binary
############################

log "Installing autheod to ${AUTHEO_BINARY}..."

install -o root -g root -m 0755 \
    "${BUILD_DIR}/build/autheod" \
    "${AUTHEO_BINARY}"

if [[ ! -x "${AUTHEO_BINARY}" ]]; then
    die "Failed to install ${AUTHEO_BINARY}."
fi

log "Installed binary version:"

"${AUTHEO_BINARY}" version

############################
# Initialize node
############################

log "Checking Autheo node initialization..."

if [[ ! -f "${AUTHEO_HOME}/config/config.toml" ]] || \
   [[ ! -f "${AUTHEO_HOME}/config/app.toml" ]]; then

    log "Initializing Autheo node as ${AUTHEO_USER}..."

    su -s /bin/bash "${AUTHEO_USER}" -c "${AUTHEO_BINARY} init '${NODE_NAME}' --chain-id='${CHAIN_ID}' --home '${AUTHEO_HOME}'"

else
    log "Autheo node is already initialized."
fi

############################
# Clone network configuration
############################

log "Preparing Autheo network configuration..."

rm -rf "${NETWORK_DIR}"

git clone --depth 1 "${NETWORK_REPO}" "${NETWORK_DIR}"

MAINNET_DIR="${NETWORK_DIR}/mainnet"

if [[ ! -d "${MAINNET_DIR}" ]]; then
    die "Mainnet directory not found: ${MAINNET_DIR}"
fi

if [[ ! -f "${MAINNET_DIR}/genesis.json" ]]; then
    die "Mainnet genesis.json not found: ${MAINNET_DIR}/genesis.json"
fi

if [[ ! -f "${MAINNET_DIR}/persistent_peers.txt" ]]; then
    die "Mainnet persistent_peers.txt not found: ${MAINNET_DIR}/persistent_peers.txt"
fi

############################
# Install genesis
############################

log "Installing mainnet genesis.json..."

install -o "${AUTHEO_USER}" -g "${AUTHEO_GROUP}" -m 0644 \
    "${MAINNET_DIR}/genesis.json" \
    "${AUTHEO_HOME}/config/genesis.json"

############################
# Read persistent peers
############################

PERSISTENT_PEERS="$(tr '\n' ',' < "${MAINNET_DIR}/persistent_peers.txt" | sed 's/,$//')"

if [[ -z "${PERSISTENT_PEERS}" ]]; then
    die "persistent_peers.txt is empty."
fi

log "Persistent peers loaded successfully."

############################
# Modify config.toml
############################

CONFIG_TOML="${AUTHEO_HOME}/config/config.toml"

if [[ ! -f "${CONFIG_TOML}" ]]; then
    die "${CONFIG_TOML} does not exist."
fi

cp -a "${CONFIG_TOML}" "${CONFIG_TOML}.bak.$(date +%Y%m%d%H%M%S)"

log "Configuring persistent_peers..."

PERSISTENT_PEERS="${PERSISTENT_PEERS}" python3 <<'PY'
from pathlib import Path
import os
import re

path = Path("/data/.autheo/config/config.toml")
value = os.environ["PERSISTENT_PEERS"]

text = path.read_text()

pattern = r'(?m)^\s*persistent_peers\s*=\s*".*"\s*$'

replacement = f'persistent_peers = "{value}"'

new_text, count = re.subn(pattern, replacement, text, count=1)

if count != 1:
    raise SystemExit(
        "Could not find exactly one persistent_peers setting in config.toml"
    )

path.write_text(new_text)
PY

############################
# Modify app.toml
############################

APP_TOML="${AUTHEO_HOME}/config/app.toml"

if [[ ! -f "${APP_TOML}" ]]; then
    die "${APP_TOML} does not exist."
fi

cp -a "${APP_TOML}" "${APP_TOML}.bak.$(date +%Y%m%d%H%M%S)"

log "Configuring minimum gas price and JSON-RPC address..."

MINIMUM_GAS_PRICES="${MINIMUM_GAS_PRICES}" \
JSON_RPC_ADDRESS="${JSON_RPC_ADDRESS}" \
python3 <<'PY'
from pathlib import Path
import os

path = Path("/data/.autheo/config/app.toml")
minimum_gas = os.environ["MINIMUM_GAS_PRICES"]
rpc_address = os.environ["JSON_RPC_ADDRESS"]

lines = path.read_text().splitlines()

gas_found = False

for i, line in enumerate(lines):
    stripped = line.strip()

    if stripped.startswith("minimum-gas-prices") and "=" in line:
        prefix = line[:len(line) - len(line.lstrip())]
        lines[i] = f'{prefix}minimum-gas-prices = "{minimum_gas}"'
        gas_found = True
        break

if not gas_found:
    raise SystemExit(
        "minimum-gas-prices setting was not found in app.toml"
    )

in_json_rpc = False
rpc_found = False

for i, line in enumerate(lines):

    stripped = line.strip()

    if stripped.startswith("[") and stripped.endswith("]"):
        in_json_rpc = stripped == "[json-rpc]"
        continue

    if in_json_rpc and stripped.startswith("address") and "=" in line:
        prefix = line[:len(line) - len(line.lstrip())]
        lines[i] = f'{prefix}address = "{rpc_address}"'
        rpc_found = True
        break

if not rpc_found:
    raise SystemExit(
        "address setting was not found inside [json-rpc] in app.toml"
    )

path.write_text("\n".join(lines) + "\n")
PY

############################
# Fix Data Directory Permissions
############################

log "Enforcing permissions on ${AUTHEO_HOME}..."

chown -R "${AUTHEO_USER}:${AUTHEO_GROUP}" "${AUTHEO_HOME}"

############################
# Validate configuration
############################

log "Validating configuration..."

grep -Eq '^[[:space:]]*persistent_peers[[:space:]]*=' \
    "${CONFIG_TOML}" || \
    die "persistent_peers configuration was not written."

grep -Eq '^[[:space:]]*minimum-gas-prices[[:space:]]*=' \
    "${APP_TOML}" || \
    die "minimum-gas-prices configuration was not written."

############################
# Create systemd service
############################

log "Creating systemd service..."

cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Autheo Mainnet Full Node Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${AUTHEO_USER}
Group=${AUTHEO_GROUP}

ExecStart=/usr/local/bin/autheod start --home=/data/.autheo --pruning=default --log_level info --json-rpc.address=0.0.0.0:8545

Restart=on-failure
RestartSec=5

LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

chmod 0644 "${SERVICE_FILE}"

############################
# Reload systemd
############################

log "Reloading systemd..."

systemctl daemon-reload

############################
# Enable service
############################

log "Enabling autheod.service..."

systemctl enable autheod.service

############################
# Start service
############################

log "Starting autheod.service..."

systemctl restart autheod.service

############################
# Service status
############################

sleep 3

if ! systemctl is-active --quiet autheod.service; then
    log "autheod.service failed to start."
    systemctl status autheod.service --no-pager -l
    journalctl -u autheod.service -n 100 --no-pager
    exit 1
fi

############################
# Final validation
############################

log "Autheo service is running."

systemctl status autheod.service --no-pager -l

log "Listening ports:"

if command -v ss >/dev/null 2>&1; then
    ss -lntp | grep ':8545' || true
fi

############################
# Cleanup
############################

rm -rf "${BUILD_DIR}"
rm -rf "${NETWORK_DIR}"

log "======================================================"
log "Autheo mainnet full node installation completed."
log "======================================================"
log "User/Group:   ${AUTHEO_USER}:${AUTHEO_GROUP}"
log "Binary:       ${AUTHEO_BINARY}"
log "Data:         ${AUTHEO_HOME}"
log "Chain ID:     ${CHAIN_ID}"
log "JSON-RPC:     ${JSON_RPC_ADDRESS}"
log "Gas price:    ${MINIMUM_GAS_PRICES}"
log "Service:      autheod.service"
log "======================================================"
