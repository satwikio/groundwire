# groundwire

MAVLink telemetry over the Siyi MK32's existing Ethernet bridge — no telemetry radio, no VPN, no internet relay.

Full write-up, wiring diagram, and test evidence: **[Groundwire report](https://claude.ai/artifact/WWcTo6o8mddPZyzCJgdgkF)**

## What's here

| File | Purpose |
|---|---|
| `setup_single_drone_telemetry.sh` | Idempotent setup script. Auto-detects the flight controller's USB serial device, installs and configures [mavlink-router](https://github.com/alireza787b/mavlink-anywhere) headlessly, then self-tests by checking for real MAVLink bytes on the wire. |
| `report.html` | Standalone copy of the report above — architecture, evidence, and the 5-drone fleet roadmap. Open it in a browser. |

## Quick start

Flight controller connected to the Jetson via USB and powered on, `sudo` available:

```bash
chmod +x setup_single_drone_telemetry.sh
./setup_single_drone_telemetry.sh
```

On success, point any MAVLink-speaking GCS (QGroundControl, Mission Planner, MAVSDK) at:

```
udp://<jetson-ip>:14550
```

Check status any time with `mla status`.

## Architecture in one line

Flight controller --USB--> Jetson (`mavlink-router`) --Ethernet--> Siyi MK32 air unit --RF (transparent L2 bridge)--> Siyi MK32 ground unit --Ethernet--> ground PC.

Next step: repeat this per drone with a unique static IP per Jetson, land all five MK32 ground units on one switch with the PC, and run MAVSDK against all five `udp://<jetson-ip>:14550` endpoints at once. Details in the report.
