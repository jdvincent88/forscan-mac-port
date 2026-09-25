# Mustang Mach-E notes

## Getting a connection

1. DLC is under the dash, left of the steering column.
2. Wake the car: brake + power button (Ready) or accessory mode. Modules sleep quickly — if a scan
   returns nothing, wake it again.
3. Keep a 12V maintainer on for anything longer than a quick read. The Mach-E's 12V battery is small
   and the car won't top it from the HV pack in every mode.
4. `fordlink setup /dev/cu.usbserial-XXXX` — confirms adapter tier, finds modules per bus, reads the
   VIN and flags the car as a Mach-E (VIN prefix `3FMTK`).
5. `fordlink scan …` — sweeps 0x700–0x7EF on every bus. **This is the source of truth for your
   car's layout**; the catalogue below only supplies labels.

## Module catalogue (labels)

| ID | Module | Bus | Confidence |
|----|--------|-----|-----------|
| 7E4 | BECM — HV battery | HS-CAN | high |
| 7E2 | SOBDMC — charging / HV supervision | HS-CAN | medium |
| 7E0 | PCM / vehicle control | HS-CAN | medium |
| 7E6 | Drive/gear control (answers "gear commanded") | HS-CAN | low |
| 6F5 | DC-charge related (unverified name) | HS-CAN | low |
| 760 / 737 / 730 / 716 | ABS / RCM / PSCM / GWM | HS-CAN | medium |
| 726 / 720 / 7D0 | BCM / IPC / SYNC 4A | pins 3/11 @ 500k | low |

## Live data

`fordlink live <adapter> --mache [--watch 2]` reads the PIDs in
`Sources/FordLinkCore/Ford/MachEPIDs.swift` — formulas from the MachEforum
"Ford Mustang Mach-E Extended PIDs for Torque Project" thread. Items marked `low` had no header in
that thread and were assigned to BECM/SOBDMC by function; confirm with
`fordlink read <adapter> 7E4 4801` style single reads.

Adding a PID is one line:

```swift
FordPID("My new value", module: 0x7E4, did: 0x48XX, unit: "V") { u16($0).map { $0 * 0.01 } },
```

## What FordLink deliberately does *not* do (yet)

* Security access (0x27), As-Built writes (0x2E), routines (0x31), or flashing. Those are where
  cars get bricked; use FORScan in a VM for them (see FORSCAN_ON_MAC.md).
* `--clear` on `fordlink dtc` is the only write operation, and it's opt-in.

## Recall awareness

Ford has issued BECM/SOBDMC software recalls/updates on 2021-2022 Mach-E (e.g. 22S41) and a BECM
state-of-charge recall reported in September 2026. Check your VIN at ford.com/support/recalls
before chasing battery DTCs — many are fixed by the dealer/OTA update.
