# Running FORScan on a Mac

FORScan (forscan.org) is closed-source, Windows-only, 32-bit x86 software distributed as an
Inno Setup installer. There is no source to port, and its licence forbids reverse engineering,
so this repo **does not modify or redistribute FORScan**. Instead:

* **FordLink** (this repo) does adapter setup, module discovery, trouble codes and Mach-E live
  data natively on macOS.
* For FORScan-only work (As-Built configuration, service procedures, module programming) you
  run the real FORScan in one of the ways below.

Installer checked into this effort (not committed):
`FORScanSetup2_3_71_release_2.exe` — SHA-256 `f5046e612851369979f60d74101762aead7afa8cf62e37e3e82d3b581458e4d6`
(Inno Setup 5.5.7, PE32 i386). Always download FORScan from forscan.org.

## Option ranking

| # | Route | Apple Silicon | Reliability | Cost | Use for |
|---|-------|---------------|-------------|------|---------|
| 1 | **Windows 11 ARM in Parallels Desktop** | ✅ (x86 emulation built into Win11 ARM) | High | Parallels subscription + Windows licence | Everything incl. programming |
| 2 | Windows 11 ARM in **VMware Fusion** (free for personal use) | ✅ | High | Windows licence | Everything incl. programming |
| 3 | **CrossOver** (commercial Wine) | ✅ via Rosetta 2 | Medium | CrossOver licence | Reading codes, live data, simple config |
| 4 | Free Wine (Gcenx builds) | ✅ via Rosetta 2 | Medium-low | Free | Same as 3, more tinkering |
| — | Boot Camp | Intel Macs only | High | Windows licence | Everything |

**Recommendation:** Parallels or VMware Fusion + OBDLink EX over USB. It is the only route where
USB timing is solid enough to trust module programming on a $50k EV.

## Option 1/2: Windows VM (recommended)

1. Install Parallels Desktop (or VMware Fusion) and let it download Windows 11 ARM.
2. In Windows, install FORScan from forscan.org (the x86 build runs under Windows' emulation).
3. Plug in the OBDLink EX. When macOS asks where to connect it, choose **Windows**
   (Parallels: *Devices › USB & Bluetooth › OBDLink EX*).
4. Windows 11 ARM installs the FTDI driver from Windows Update; check *Device Manager › Ports*
   for the COM number.
5. FORScan › Settings › Connection: select that COM port (or "Auto"), then connect.
6. Licence: FORScan's Extended licence is tied to a hardware ID; generate it **inside the VM**.
   Re-cloning the VM can change the ID.

## Option 3/4: Wine / CrossOver

```bash
# One-time: Rosetta (Apple Silicon) + a Wine
softwareupdate --install-rosetta --agree-to-license
brew tap gcenx/wine && brew install --cask --no-quarantine wine-crossover   # or install CrossOver

# Install FORScan (accepts the .exe, a .zip, or a split .zip + .z01 pair)
scripts/forscan-wine.sh install ~/Downloads/FORScanSetup2_3_71.zip

# Map COM1 to the USB adapter (auto-detects /dev/cu.usbserial*)
scripts/forscan-wine.sh map

# Launch
scripts/forscan-wine.sh run
```

In FORScan: *Settings › Connection › Connection type: COM, Port: COM1*.

Known limits under Wine:
* **USB serial only.** Bluetooth adapters work only if paired so macOS exposes `/dev/cu.*`.
* **FTDI D2XX mode** (FORScan's fast path for some adapters) is not available; FORScan falls back
  to COM mode, which is slower but works.
* **Do not program modules** (PMI / firmware flashing) under Wine — a dropped frame can brick a
  module. Use a VM.

## Safety checklist before any configuration or programming

- [ ] 12V battery maintainer connected (Mach-E: the 12V drops fast with the car awake).
- [ ] Mach-E in "Ready" or ignition-on per FORScan's prompt; doors closed; not charging.
- [ ] Mac on AC power, sleep disabled (`caffeinate -dimsu &`).
- [ ] USB adapter (not Wi-Fi/BLE).
- [ ] Save the module's As-Built data (FORScan › Configuration › save) before editing.
