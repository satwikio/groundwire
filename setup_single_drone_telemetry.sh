#!/usr/bin/env bash
#
# setup_single_drone_telemetry.sh
#
# Sets up mavlink-router on this Jetson so that any MAVLink Ground Control
# Station (QGroundControl, Mission Planner, MAVSDK, etc.) reachable over the
# network can pull live telemetry from the flight controller plugged into
# this Jetson via USB.
#
# WHAT THIS SCRIPT DOES (in order):
#   1. Finds the flight controller's USB serial device automatically.
#   2. Clones mavlink-anywhere (https://github.com/alireza787b/mavlink-anywhere)
#      if it isn't already present next to this script.
#   3. Installs mavlink-router (skips rebuild if already installed).
#   4. Configures mavlink-router in headless (non-interactive) mode:
#        - Input:  the flight controller's USB serial port
#        - Output: a UDP server on 0.0.0.0:14550 that any GCS on the network
#                  can connect to, plus local loopback outputs for MAVSDK
#                  (14540) and mavlink2rest (14569) if you use those later.
#   5. Starts and enables the mavlink-router systemd service (survives reboot).
#   6. Runs a live self-test: listens on the local MAVSDK UDP port and checks
#      that real MAVLink bytes (starting with 0xFE or 0xFD) are actually
#      arriving from the flight controller -- not just that the service is
#      "running".
#
# REQUIREMENTS:
#   - Flight controller (Pixhawk/PX4 or ArduPilot) connected to this Jetson
#     via USB, powered on.
#   - This Jetson's network-facing Ethernet port already has an IP address
#     on the same subnet your ground station will reach it on (e.g. the
#     Siyi MK32 / 192.168.144.0/24 network). This script does not configure
#     that -- it only asks you to confirm it.
#   - sudo privileges (you will be prompted for your password interactively).
#
# USAGE:
#   chmod +x setup_single_drone_telemetry.sh
#   ./setup_single_drone_telemetry.sh
#
# You can re-run this script safely at any time -- it is idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAVLINK_ANYWHERE_DIR="${SCRIPT_DIR}/mavlink-anywhere"
MAVLINK_ANYWHERE_REPO="https://github.com/alireza787b/mavlink-anywhere.git"

BAUD="57600"          # Ignored for USB (CDC-ACM) flight controllers, kept for UART boards.
GCS_PORT="14550"      # Standard MAVLink GCS port. QGroundControl/Mission Planner expect this.

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
info()  { printf '  [->] %s\n' "$*"; }
ok()    { printf '  [OK] %s\n' "$*"; }
warn()  { printf '  [!!] %s\n' "$*"; }
fail()  { printf '  [XX] %s\n' "$*"; exit 1; }

bold "=================================================================="
bold " Step 1/6 - Locate the flight controller's USB serial device"
bold "=================================================================="

FC_DEVICE=""
if [[ -d /dev/serial/by-id ]]; then
    for dev in /dev/serial/by-id/*; do
        [[ -e "$dev" ]] || continue
        FC_DEVICE="$(readlink -f "$dev")"
        info "Found by-id device: $(basename "$dev") -> ${FC_DEVICE}"
        break
    done
fi
if [[ -z "$FC_DEVICE" ]]; then
    for candidate in /dev/ttyACM0 /dev/ttyACM1 /dev/ttyUSB0; do
        if [[ -e "$candidate" ]]; then
            FC_DEVICE="$candidate"
            break
        fi
    done
fi

if [[ -z "$FC_DEVICE" ]]; then
    fail "No flight controller serial device found. Plug in the FC via USB, power it on, and re-run this script. (Checked /dev/serial/by-id, /dev/ttyACM0, /dev/ttyACM1, /dev/ttyUSB0)"
fi
ok "Flight controller device: ${FC_DEVICE}"

bold ""
bold "=================================================================="
bold " Step 2/6 - Confirm this Jetson's network address"
bold "=================================================================="
info "Current IPv4 addresses on this Jetson:"
ip -4 -o addr show | awk '{print "        " $2, $4}'
echo ""
read -r -p "  Is this Jetson's Ethernet IP (the one your GCS/PC will connect to) already set and correct above? [y/N]: " ip_confirm
if [[ ! "$ip_confirm" =~ ^[Yy] ]]; then
    fail "Set a static IP on this Jetson's Ethernet interface first (e.g. via nmcli/netplan), then re-run this script."
fi

bold ""
bold "=================================================================="
bold " Step 3/6 - Get mavlink-anywhere"
bold "=================================================================="
if [[ -d "$MAVLINK_ANYWHERE_DIR" ]]; then
    ok "mavlink-anywhere already present at ${MAVLINK_ANYWHERE_DIR}"
else
    info "Cloning mavlink-anywhere..."
    git clone --depth 1 "$MAVLINK_ANYWHERE_REPO" "$MAVLINK_ANYWHERE_DIR"
    ok "Cloned."
fi

bold ""
bold "=================================================================="
bold " Step 4/6 - Install mavlink-router"
bold "=================================================================="
( cd "$MAVLINK_ANYWHERE_DIR" && sudo ./install_mavlink_router.sh )

bold ""
bold "=================================================================="
bold " Step 5/6 - Configure mavlink-router (headless, non-interactive)"
bold "=================================================================="
(
    cd "$MAVLINK_ANYWHERE_DIR" && sudo ./configure_mavlink_router.sh \
        --headless \
        --uart "$FC_DEVICE" \
        --baud "$BAUD" \
        --skip-serial-check \
        --skip-dashboard \
        --endpoints "127.0.0.1:14540,127.0.0.1:14569"
)
ok "mavlink-router configured and (re)started."

bold ""
bold "=================================================================="
bold " Step 6/6 - Self-test: confirm real MAVLink bytes are flowing"
bold "=================================================================="
info "Listening on local UDP 14540 for 5 seconds..."
python3 - "$GCS_PORT" <<'PYEOF'
import socket, sys

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("127.0.0.1", 14540))
s.settimeout(5)
try:
    data, _ = s.recvfrom(1024)
    if data[0] in (0xFE, 0xFD):
        print(f"  [OK] Received {len(data)} bytes, starts with MAVLink marker 0x{data[0]:02X}")
        print(f"       First bytes: {data[:16].hex()}")
        sys.exit(0)
    else:
        print(f"  [!!] Received {len(data)} bytes but they do not look like MAVLink: {data[:16].hex()}")
        sys.exit(1)
except socket.timeout:
    print("  [XX] No data received in 5 seconds. Check FC power/wiring and re-run.")
    sys.exit(1)
PYEOF
TEST_RESULT=$?

echo ""
if [[ $TEST_RESULT -eq 0 ]]; then
    bold "=================================================================="
    bold " SUCCESS"
    bold "=================================================================="
    JETSON_IP="$(ip -4 -o addr show | awk '/scope global/{print $4}' | cut -d/ -f1 | grep -v '^172\.' | head -1)"
    echo "  mavlink-router is running and streaming live MAVLink data."
    echo ""
    echo "  On your Ground Control PC, connect via UDP to:"
    echo "      Host: ${JETSON_IP:-<this-jetson-ip>}"
    echo "      Port: ${GCS_PORT}"
    echo ""
    echo "  Check status any time with:  mla status"
    echo "  Watch logs with:             sudo journalctl -u mavlink-router -f"
else
    warn "Setup finished but the live-data self-test failed. Check FC wiring/power and run:"
    warn "  sudo journalctl -u mavlink-router -n 50"
    exit 1
fi
