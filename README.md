# FordLink — Ford OBD setup & diagnostics for macOS (Mustang Mach-E focused)

Native Mac tool for setting up OBD adapters on Ford vehicles, plus a guided path to run
FORScan itself on a Mac.

> **Why not a straight FORScan port?** FORScan is closed-source 32-bit Windows software
> (Inno Setup installer, no source) and its licence forbids reverse engineering. So this repo
> does two things instead:
> 1. **FordLink** — a native Swift app + CLI that does the adapter/bus setup FORScan needs,
>    module discovery, trouble codes and Mach-E battery/charging live data.
> 2. **FORScan on Mac** — scripts/docs to run the real FORScan in a VM or Wine
>    ([docs/FORSCAN_ON_MAC.md](docs/FORSCAN_ON_MAC.md)).

## Features

| | |
|---|---|
| Adapters | USB serial (OBDLink EX/SX, vLinker, ELM327), Bluetooth Classic (paired `/dev/cu.*`), Wi-Fi (TCP 35000), Bluetooth LE (CoreBluetooth) |
| Setup wizard | Auto-baud, identifies ELM vs STN/OBDLink, tests Ford-critical commands, grades the adapter (4 tiers), checks 12V, probes HS-CAN / MS-CAN / HS-CAN on pins 3/11, reads VIN, detects Mach-E |
| Ford buses | `STP 33`/`STP 53`/`STPBR` on OBDLink; `ATSP6` / `ATPB 81 xx` + `ATSPB` on switched ELM327 |
| Diagnostics | UDS over ISO-TP (own reassembly), module sweep 0x700–0x7EF per bus, DTC read (0x19) with Ford-format codes, optional clear |
| Mach-E | 26 community-sourced BECM/SOBDMC PIDs: SoC, HV V/A/kW, temps, isolation, charger/EVSE state |
| Simulator | Built-in ELM327/STN + Mach-E emulator (`sim:mache`) — try everything with no car |

## Quick start (Mac)

```bash
xcode-select --install            # once, if you don't have Xcode
git clone <this repo> && cd forscan-mac-port
scripts/build-app.sh              # → dist/FordLink.app and dist/fordlink

dist/fordlink setup sim:mache     # dry run against the simulator
dist/fordlink ports               # find your adapter
dist/fordlink setup /dev/cu.usbserial-XXXX
dist/fordlink scan  /dev/cu.usbserial-XXXX
dist/fordlink live  /dev/cu.usbserial-XXXX --mache --watch 2
open dist/FordLink.app
```

Or without building an app bundle: `swift run fordlink setup sim:mache` / `swift run FordLinkApp`.

CI (`.github/workflows/build.yml`) builds and tests on Linux and macOS and uploads the app as a
workflow artifact.

## Layout

```
Sources/FordLinkCore/
  Transport/   Serial (termios), TCP, BLE (CoreBluetooth), VehicleSimulator
  ELM/         ELM327/STN driver, ISO-TP frame reassembly, hex utils
  UDS/         ISO 14229 client: 0x22, 0x19, 0x14, 0x3E, NRC handling (incl. 0x78 pending)
  Ford/        Ford module catalogue, Mach-E PIDs, VIN helpers
  Setup/       AdapterSetup wizard + ModuleScanner
Sources/fordlink/     CLI
Sources/FordLinkApp/  SwiftUI app (macOS 13+)
scripts/              build-app.sh, forscan-wine.sh
docs/                 FORSCAN_ON_MAC.md, ADAPTERS.md, MACH-E.md
```

## Status / roadmap

- [x] Adapter setup + grading, bus probing, module scan, DTCs, Mach-E live data, simulator, tests
- [ ] Verify Mach-E module map & low-confidence PIDs on a real car (`fordlink scan` output welcome)
- [ ] CSV logging of live data; charge-session graphs
- [ ] As-Built read (read-only) and backup
- [ ] Signed/notarised release build

**Buy:** OBDLink EX (USB) for programming-grade reliability; OBDLink MX+ if you want wireless.
See [docs/ADAPTERS.md](docs/ADAPTERS.md).

## Disclaimer

Not affiliated with Ford or FORScan. Reading data is safe; clearing codes and anything written to a
module is at your own risk. Keep a 12V maintainer on the car.
