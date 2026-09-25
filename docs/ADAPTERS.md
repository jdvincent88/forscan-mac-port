# OBD adapters for Ford / Mach-E on macOS

Ford splits modules across more than one CAN bus on the OBD port (DLC):

| Bus | DLC pins | Speed | What's there |
|-----|----------|-------|--------------|
| HS-CAN (HS1) | 6 / 14 | 500 kbps | PCM, BECM, ABS, RCM, legislated OBD-II |
| MS-CAN | 3 / 11 | 125 kbps | Body/comfort on most 2005-2019 Fords |
| HS-CAN on 3/11 (HS2/HS3) | 3 / 11 | 500 kbps | Body/infotainment on newer platforms incl. Mach-E |

A plain ELM327 only has a transceiver on 6/14. To reach 3/11 you need either a second transceiver
(OBDLink EX/MX+) or a clone with a physical HS/MS switch.

## Ranking

| Rank | Adapter | Link | Mac connection | Pins 3/11 | Notes |
|------|---------|------|----------------|-----------|-------|
| 1 | **OBDLink EX** | USB | `/dev/cu.usbserial-*`, built-in FTDI driver | ✅ auto | FORScan's recommended adapter. Best for programming. |
| 2 | OBDLink MX+ | Bluetooth Classic | Pair → `/dev/cu.OBDLinkMX*` | ✅ auto | Great for reading/config; use USB for programming. |
| 3 | vLinker FS USB | USB | `/dev/cu.usbserial-*` / `cu.wchusbserial*` | ✅ auto | Good budget FORScan adapter. |
| 4 | Switched ELM327 USB (genuine PIC18F25K80 clone) | USB | CH340 driver may be needed | ⚠︎ manual switch | Works; you flip HS/MS when prompted. |
| 5 | OBDLink SX / CX / LX | USB / BLE / BT | — | ❌ | HS-CAN only — BECM/battery data yes, body modules no. |
| 6 | Generic "v2.1" Bluetooth/Wi-Fi clone | BT/Wi-Fi | — | ❌ | Often missing `ATPB`/flow control. Avoid. |

`fordlink setup <adapter>` classifies whatever you plug in into exactly these tiers.

## How FordLink selects buses

* **OBDLink (STN chip)** — protocol numbers from the *OBDLink Family Reference and Programming
  Manual*: `STP 33` = ISO 15765 11-bit 500 kbps (HS-CAN); `STP 53` = ISO 15765 11-bit 125 kbps on
  the MS-CAN transceiver (pins 3/11); `STPBR 500000` raises pins 3/11 to 500 kbps for HS2/HS3.
* **ELM327** — `ATSP6` for HS-CAN; user protocol B with `ATPB 81 04` (11-bit, DLC 8, ISO 15765,
  500/4 = 125 kbps) or `ATPB 81 01` (500 kbps) plus a manual switch for pins 3/11.

## macOS driver notes

* FTDI (OBDLink EX, most genuine adapters): driver built into macOS 11+. Nothing to install.
* CH340/CH341 clones: macOS 11+ includes a driver; if the port doesn't appear, install WCH's
  signed driver and allow it in *System Settings › Privacy & Security*.
* Always use `/dev/cu.*`, never `/dev/tty.*`.
* Bluetooth Classic adapters: pair in *System Settings › Bluetooth* (PIN usually 1234 or 0000).
