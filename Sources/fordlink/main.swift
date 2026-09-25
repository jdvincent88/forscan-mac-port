import Foundation
import FordLinkCore

setvbuf(stdout, nil, _IONBF, 0)

let usage = """
fordlink — Ford OBD adapter setup & diagnostics (Mustang Mach-E aware)

USAGE
  fordlink ports                         List USB / Bluetooth serial adapters
  fordlink setup   <adapter> [-v]        Identify adapter, test Ford buses, read VIN, advise
  fordlink scan    <adapter> [--mache]   Sweep 0x700-0x7EF on every reachable bus
  fordlink dtc     <adapter> [--module 7E4 ...] [--clear]
  fordlink live    <adapter> [--mache] [--watch SECONDS]
  fordlink read    <adapter> <module> <DID>      e.g. read /dev/cu.usbserial-X 7E4 4801
  fordlink terminal <adapter>            Interactive AT/ST/hex terminal
  fordlink pids                          List known Mach-E PIDs

ADAPTER
  /dev/cu.usbserial-XXXX[@baud]   USB (OBDLink EX/SX, vLinker, ELM327 USB). Baud auto-detected.
  /dev/cu.OBDLinkMX-XXXX          Classic Bluetooth (pair in System Settings first)
  wifi | tcp:192.168.0.10:35000   Wi-Fi ELM327
  ble:<name>                      Bluetooth LE (OBDLink CX, vLinker BLE) — macOS only
  sim:mache | sim:mache-clone | sim:novehicle   Built-in simulator (no hardware)
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + msg + "\n").utf8))
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

func flag(_ name: String) -> Bool {
    if let i = args.firstIndex(of: name) { args.remove(at: i); return true }
    return false
}
func option(_ name: String) -> [String] {
    var vals: [String] = []
    while let i = args.firstIndex(of: name), i + 1 < args.count {
        vals.append(args[i + 1]); args.removeSubrange(i...(i + 1))
    }
    return vals
}
func endpointArg() -> AdapterEndpoint {
    guard let raw = args.first else { fail("missing <adapter>. Try `fordlink ports`.") }
    args.removeFirst()
    guard let ep = AdapterEndpoint.parse(raw) else { fail("can't understand adapter '\(raw)'") }
    return ep
}
func connect(_ ep: AdapterEndpoint, verbose: Bool) -> ELM327 {
    let s = AdapterSetup(endpoint: ep)
    if verbose { s.trace = { print("    \($0)") } }
    do { return try s.connect().0 } catch { fail("\(error)") }
}
func parseID(_ s: String) -> UInt32 {
    guard let v = Hex.uint32(s.replacingOccurrences(of: "0x", with: "")) else { fail("bad hex id \(s)") }
    return v
}

switch command {
case "ports":
    let ports = SerialTransport.availablePorts()
    if ports.isEmpty {
        print("No serial adapters found.\n• USB: plug in; OBDLink EX uses the built-in macOS FTDI driver (no install on macOS 11+).\n• CH340-based clones need the WCH driver.\n• Bluetooth Classic (MX+): pair in System Settings › Bluetooth, then re-run.")
    } else {
        ports.forEach { print($0) }
    }

case "setup":
    let verbose = flag("-v")
    let ep = endpointArg()
    let setup = AdapterSetup(endpoint: ep)
    setup.progress = { print("• \($0)") }
    if verbose { setup.trace = { print("    \($0)") } }
    do {
        let rep = try setup.run()
        print("\n" + rep.summary())
    } catch { fail("\(error)") }

case "scan":
    let mache = flag("--mache")
    let verbose = flag("-v")
    let ep = endpointArg()
    let setup = AdapterSetup(endpoint: ep)
    do {
        let rep = try setup.run()
        let uds = UDSClient(elm: setup.elm!)
        if verbose { setup.elm?.log = { print("    \($0)") } }
        let scanner = ModuleScanner(uds: uds)
        var last = -1
        scanner.progress = { p, _ in let pct = Int(p * 100); if pct / 10 != last / 10 { last = pct; print("  scanning… \(pct)%") } }
        let found = scanner.scan(buses: rep.usableBuses, machE: mache || rep.isMachE)
        print("\nBUS                  ID    MODULE")
        for f in found {
            print("\(f.bus.rawValue.padding(toLength: 20, withPad: " ", startingAt: 0)) \(Hex.id(f.requestID))   \(f.label)\(f.partNumber.map { "  [\($0)]" } ?? "")")
        }
        print("\n\(found.count) module(s) found.")
    } catch { fail("\(error)") }

case "dtc":
    let clear = flag("--clear")
    let mods = option("--module").map(parseID)
    let ep = endpointArg()
    let elm = connect(ep, verbose: false)
    let uds = UDSClient(elm: elm)
    let targets: [FordModule] = mods.isEmpty
        ? FordModuleCatalog.machE + FordModuleCatalog.common.filter { c in !FordModuleCatalog.machE.contains { $0.requestID == c.requestID } }
        : mods.map { id in FordModuleCatalog.label(for: id, machE: true) ?? FordModule("?", "Module", id, .hsCAN, .low) }
    for m in targets {
        // Try the catalogued bus first, then the others.
        for bus in [m.bus] + FordBus.allCases.filter({ $0 != m.bus }) {
            do {
                let dtcs = try uds.readDTCs(module: m.requestID, bus: bus)
                print("\(m.acronym) \(Hex.id(m.requestID)) [\(bus)]: \(dtcs.isEmpty ? "no codes" : "")")
                dtcs.forEach { print("    \($0)") }
                if clear && !dtcs.isEmpty {
                    try uds.clearDTCs(module: m.requestID, bus: bus)
                    print("    cleared.")
                }
                break
            } catch UDSError.noResponse { continue }
            catch ELMError.unsupportedCommand { continue }
            catch { print("\(m.acronym) \(Hex.id(m.requestID)) [\(bus)]: \(error)"); break }
        }
    }

case "live":
    _ = flag("--mache")
    let watch = option("--watch").first.flatMap(Double.init)
    let ep = endpointArg()
    let elm = connect(ep, verbose: false)
    let reader = LiveDataReader(uds: UDSClient(elm: elm))
    repeat {
        let readings = reader.read(MachEPIDs.all)
        for r in readings {
            print("\(r.pid.name.padding(toLength: 34, withPad: " ", startingAt: 0)) \(r.formatted)")
        }
        if let kw = LiveDataReader.batteryPowerKW(readings) { print(String(format: "%@ %.2f kW", "HV battery power (calc)".padding(toLength: 34, withPad: " ", startingAt: 0), kw)) }
        if let w = watch { print("—"); Thread.sleep(forTimeInterval: w) }
    } while watch != nil

case "read":
    let ep = endpointArg()
    guard args.count >= 2 else { fail("usage: fordlink read <adapter> <module> <DID>") }
    let module = parseID(args[0])
    let did = UInt16(parseID(args[1]) & 0xFFFF)
    let bus = FordBus(rawValue: option("--bus").first ?? "") ?? .hsCAN
    let elm = connect(ep, verbose: false)
    do {
        let b = try UDSClient(elm: elm).readDID(module: module, bus: bus, did: did)
        print(Hex.string(b))
        let ascii = String(decoding: b.filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
        if ascii.count == b.count && !b.isEmpty { print("\"\(ascii)\"") }
    } catch { fail("\(error)") }

case "terminal":
    let ep = endpointArg()
    let elm = connect(ep, verbose: false)
    print("Connected. Type AT/ST commands or hex requests; 'quit' to exit.")
    while true {
        print("> ", terminator: "")
        guard let line = readLine(), line != "quit", line != "exit" else { break }
        do { try elm.send(line, timeout: 5).forEach { print($0) } } catch { print("! \(error)") }
    }

case "pids":
    for p in MachEPIDs.all {
        print("\(Hex.id(p.module)) 22\(String(format: "%04X", p.did))  \(p.name) [\(p.unit)] confidence=\(p.confidence.rawValue)")
    }

case "-h", "--help", "help":
    print(usage)

default:
    fail("unknown command '\(command)'\n\n\(usage)")
}
