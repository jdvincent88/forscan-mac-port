#if os(macOS)
import Foundation
import SwiftUI
import FordLinkCore

enum EndpointKind: String, CaseIterable, Identifiable {
    case usb = "USB / Bluetooth serial"
    case wifi = "Wi-Fi"
    case ble = "Bluetooth LE"
    case simulator = "Simulator"
    var id: String { rawValue }
}

struct DTCRow: Identifiable {
    let id = UUID()
    let module: String
    let bus: String
    let code: String
    let flags: String
}

final class AppModel: ObservableObject {
    // Connection form
    @Published var kind: EndpointKind = .usb
    @Published var ports: [String] = []
    @Published var selectedPort = ""
    @Published var baud = 0 // 0 = auto
    @Published var wifiHost = "192.168.0.10"
    @Published var wifiPort = "35000"
    @Published var bleName = "OBDLink"
    @Published var simProfile: VehicleSimulator.Profile = .machE

    // State
    @Published var busy = false
    @Published var status = "Not connected"
    @Published var steps: [String] = []
    @Published var trace: [String] = []
    @Published var report: AdapterReport?
    @Published var modules: [ModuleScanner.Found] = []
    @Published var scanProgress: Double = 0
    @Published var dtcs: [DTCRow] = []
    @Published var readings: [LiveDataReader.Reading] = []
    @Published var batteryKW: Double?
    @Published var liveRunning = false
    @Published var terminalLines: [String] = []

    private var elm: ELM327?
    private let worker = DispatchQueue(label: "fordlink.worker")

    var isConnected: Bool { elm != nil }

    init() { refreshPorts() }

    func refreshPorts() {
        ports = SerialTransport.availablePorts()
        if !ports.contains(selectedPort) { selectedPort = ports.first ?? "" }
    }

    var endpoint: AdapterEndpoint? {
        switch kind {
        case .usb: return selectedPort.isEmpty ? nil : .serial(path: selectedPort, baud: baud)
        case .wifi: return .tcp(host: wifiHost, port: UInt16(wifiPort) ?? 35000)
        case .ble: return .bluetoothLE(nameOrUUID: bleName)
        case .simulator: return .simulator(simProfile)
        }
    }

    private func onMain(_ f: @escaping () -> Void) { DispatchQueue.main.async(execute: f) }

    private func run(_ label: String, _ job: @escaping () throws -> Void) {
        guard !busy else { return }
        busy = true
        status = label
        worker.async {
            do { try job() } catch {
                self.onMain { self.status = "Error: \(error)" }
            }
            self.onMain { self.busy = false }
        }
    }

    // MARK: Actions

    func runSetup() {
        guard let ep = endpoint else { status = "Choose an adapter first"; return }
        disconnect()
        steps = []; trace = []; report = nil
        run("Running adapter setup…") {
            let setup = AdapterSetup(endpoint: ep)
            setup.progress = { s in self.onMain { self.steps.append(s) } }
            setup.trace = { s in self.onMain { self.trace.append(s); if self.trace.count > 2000 { self.trace.removeFirst(500) } } }
            let rep = try setup.run()
            self.onMain {
                self.elm = setup.elm
                self.report = rep
                self.status = "Connected: \(rep.deviceName ?? rep.elmVersion)"
            }
        }
    }

    func disconnect() {
        liveRunning = false
        let e = elm
        elm = nil
        worker.async { e?.transport.close() }
        status = "Not connected"
    }

    func scanModules() {
        guard let elm, let rep = report else { status = "Run setup first"; return }
        modules = []; scanProgress = 0
        run("Scanning modules…") {
            let s = ModuleScanner(uds: UDSClient(elm: elm))
            s.progress = { p, _ in self.onMain { self.scanProgress = p } }
            let found = s.scan(buses: rep.usableBuses, machE: rep.isMachE)
            self.onMain { self.modules = found; self.status = "\(found.count) modules found" }
        }
    }

    func readDTCs() {
        guard let elm, let rep = report else { status = "Run setup first"; return }
        dtcs = []
        let targets: [(UInt32, FordBus, String)] = modules.isEmpty
            ? (rep.isMachE ? FordModuleCatalog.machE : FordModuleCatalog.common).map { ($0.requestID, $0.bus, $0.acronym) }
            : modules.map { ($0.requestID, $0.bus, String($0.label.split(separator: " ").first ?? "?")) }
        run("Reading trouble codes…") {
            let uds = UDSClient(elm: elm)
            var rows: [DTCRow] = []
            for (id, bus, name) in targets where rep.usableBuses.contains(bus) {
                guard let list = try? uds.readDTCs(module: id, bus: bus) else { continue }
                if list.isEmpty {
                    rows.append(DTCRow(module: "\(name) \(Hex.id(id))", bus: bus.rawValue, code: "—", flags: "no codes"))
                }
                for d in list {
                    rows.append(DTCRow(module: "\(name) \(Hex.id(id))", bus: bus.rawValue, code: d.code, flags: d.flags.joined(separator: ", ")))
                }
            }
            self.onMain { self.dtcs = rows; self.status = "Read codes from \(Set(rows.map(\.module)).count) modules" }
        }
    }

    func toggleLive() {
        if liveRunning { liveRunning = false; return }
        guard let elm else { status = "Run setup first"; return }
        liveRunning = true
        status = "Live data running"
        worker.async {
            let reader = LiveDataReader(uds: UDSClient(elm: elm))
            let dash = MachEPIDs.all
            while true {
                var keep = false
                DispatchQueue.main.sync { keep = self.liveRunning && self.elm != nil }
                if !keep { break }
                let r = reader.read(dash)
                self.onMain { self.readings = r; self.batteryKW = LiveDataReader.batteryPowerKW(r) }
                Thread.sleep(forTimeInterval: 1.0)
            }
            self.onMain { self.status = "Live data stopped" }
        }
    }

    func sendTerminal(_ cmd: String) {
        guard let elm else { terminalLines.append("! not connected — run setup first"); return }
        terminalLines.append("> \(cmd)")
        worker.async {
            let out: [String]
            do { out = try elm.send(cmd, timeout: 5) } catch { out = ["! \(error)"] }
            self.onMain { self.terminalLines.append(contentsOf: out) }
        }
    }
}
#endif
