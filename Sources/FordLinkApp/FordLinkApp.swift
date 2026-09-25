#if os(macOS)
import SwiftUI
import FordLinkCore

struct FordLinkApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("FordLink") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}

enum Pane: String, CaseIterable, Identifiable {
    case setup = "Adapter Setup"
    case modules = "Modules"
    case dtcs = "Trouble Codes"
    case live = "Mach-E Live Data"
    case terminal = "Terminal"
    case forscan = "FORScan on Mac"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .setup: return "cable.connector"
        case .modules: return "square.grid.3x3"
        case .dtcs: return "exclamationmark.triangle"
        case .live: return "bolt.car"
        case .terminal: return "terminal"
        case .forscan: return "desktopcomputer"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var pane: Pane? = .setup

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { p in
                Label(p.rawValue, systemImage: p.icon).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            VStack(spacing: 0) {
                switch pane ?? .setup {
                case .setup: SetupView()
                case .modules: ModulesView()
                case .dtcs: DTCView()
                case .live: LiveView()
                case .terminal: TerminalView()
                case .forscan: ForscanHelpView()
                }
                Divider()
                HStack {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.status).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if model.isConnected { Button("Disconnect") { model.disconnect() } }
                }
                .padding(8)
            }
        }
    }
}

struct SetupView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HSplitView {
            Form {
                Section("Adapter") {
                    Picker("Connection", selection: $model.kind) {
                        ForEach(EndpointKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    switch model.kind {
                    case .usb:
                        HStack {
                            Picker("Port", selection: $model.selectedPort) {
                                if model.ports.isEmpty { Text("No adapters found").tag("") }
                                ForEach(model.ports, id: \.self) { Text($0).tag($0) }
                            }
                            Button { model.refreshPorts() } label: { Image(systemName: "arrow.clockwise") }
                        }
                        Picker("Baud", selection: $model.baud) {
                            Text("Auto-detect").tag(0)
                            ForEach(AdapterSetup.serialBaudCandidates, id: \.self) { Text("\($0)").tag($0) }
                        }
                        Text("OBDLink EX/SX: use the cu.usbserial port. Bluetooth Classic (OBDLink MX+): pair in System Settings first; it then appears here.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .wifi:
                        TextField("Host", text: $model.wifiHost)
                        TextField("Port", text: $model.wifiPort)
                        Text("Join the adapter's Wi-Fi network (often 'WiFi_OBDII' or 'V-LINK') before connecting.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .ble:
                        TextField("Name contains", text: $model.bleName)
                        Text("For BLE adapters such as OBDLink CX or vLinker BLE. macOS will ask for Bluetooth permission.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .simulator:
                        Picker("Scenario", selection: $model.simProfile) {
                            Text("OBDLink EX + Mach-E").tag(VehicleSimulator.Profile.machE)
                            Text("Cheap clone + Mach-E").tag(VehicleSimulator.Profile.machEClone)
                            Text("Adapter, ignition off").tag(VehicleSimulator.Profile.noVehicle)
                        }
                    }
                    Button(action: model.runSetup) {
                        Label("Run Setup & Compatibility Check", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy)
                }
                Section("Progress") {
                    ForEach(Array(model.steps.enumerated()), id: \.offset) { Text($0.element).font(.callout) }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 320)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let r = model.report {
                        ReportView(report: r)
                    } else {
                        Text("Plug the adapter into the DLC (under the dash, left of the steering column), turn the Mach-E on, then run setup.")
                            .foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Adapter traffic (\(model.trace.count) lines)") {
                        Text(model.trace.suffix(300).joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .frame(minWidth: 380)
        }
    }
}

struct ReportView: View {
    let report: AdapterReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(report.deviceName ?? report.elmVersion).font(.title2.bold())
            Text(report.adapterClass.rawValue)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(badgeColor.opacity(0.2), in: Capsule())
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Firmware", "\(report.elmVersion)\(report.stnVersion.map { " / \($0)" } ?? "")")
                row("Connection", report.endpoint + (report.baud.map { " @ \($0)" } ?? ""))
                if let v = report.voltage { row("12V at DLC", String(format: "%.1f V", v)) }
                if let vin = report.vin { row("VIN", vin + (report.isMachE ? "  (Mustang Mach-E)" : "")) }
                if let y = report.modelYear { row("Model year", "\(y)") }
                ForEach(report.buses.sorted(by: { $0.key < $1.key }), id: \.key) { pair in
                    row(pair.key, pair.value.isEmpty ? "no response" : pair.value.joined(separator: ", "))
                }
                ForEach(report.supported.sorted(by: { $0.key < $1.key }), id: \.key) { pair in
                    row(pair.key, pair.value ? "✓" : "✗")
                }
            }
            ForEach(report.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            ForEach(report.recommendations, id: \.self) { Label($0, systemImage: "arrow.right.circle") }
        }
    }

    private var badgeColor: Color {
        switch report.adapterClass {
        case .stnWithMSCAN: return .green
        case .elmSwitchable, .stnHSOnly: return .yellow
        default: return .red
        }
    }

    @ViewBuilder private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled)
        }
    }
}

struct ModulesView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button("Scan All Buses", action: model.scanModules).disabled(model.busy || !model.isConnected)
                if model.busy && model.scanProgress > 0 { ProgressView(value: model.scanProgress).frame(width: 200) }
                Spacer()
            }
            Table(model.modules) {
                TableColumn("Bus") { Text($0.bus.rawValue) }
                TableColumn("ID") { Text(Hex.id($0.requestID)).font(.body.monospaced()) }
                TableColumn("Module") { Text($0.label) }
                TableColumn("Software P/N") { Text($0.partNumber ?? "") }
            }
        }
        .padding()
    }
}

struct DTCView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button("Read Codes", action: model.readDTCs).disabled(model.busy || !model.isConnected)
                Text("Reads every scanned module (or the Mach-E catalogue if you haven't scanned). Read-only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Table(model.dtcs) {
                TableColumn("Module", value: \.module)
                TableColumn("Bus", value: \.bus)
                TableColumn("Code") { Text($0.code).font(.body.monospaced()) }
                TableColumn("Status", value: \.flags)
            }
        }
        .padding()
    }
}

struct LiveView: View {
    @EnvironmentObject var model: AppModel

    private func value(_ name: String) -> Double? { model.readings.first { $0.pid.name == name }?.value }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button(model.liveRunning ? "Stop" : "Start Live Data", action: model.toggleLive)
                    .disabled(!model.isConnected)
                Text("Community-sourced Mach-E PIDs (MachEforum). Low-confidence items may not decode on every build.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Tile(title: "State of charge", value: value("HV battery SoC (displayed)").map { String(format: "%.1f %%", $0) })
                Tile(title: "HV voltage", value: value("HV battery voltage").map { String(format: "%.1f V", $0) })
                Tile(title: "HV current", value: value("HV battery current").map { String(format: "%.1f A", $0) })
                Tile(title: "Battery power", value: model.batteryKW.map { String(format: "%.2f kW", $0) })
                Tile(title: "Battery temp", value: value("HV battery temperature").map { String(format: "%.0f °F", $0) })
            }
            Table(model.readings) {
                TableColumn("Item") { Text($0.pid.name) }
                TableColumn("Module") { Text(Hex.id($0.pid.module)).font(.body.monospaced()) }
                TableColumn("DID") { Text(String(format: "%04X", $0.pid.did)).font(.body.monospaced()) }
                TableColumn("Value") { Text($0.formatted) }
                TableColumn("Confidence") { Text($0.pid.confidence.rawValue) }
            }
        }
        .padding()
    }
}

struct Tile: View {
    let title: String
    let value: String?
    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "—").font(.title.monospacedDigit().bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct TerminalView: View {
    @EnvironmentObject var model: AppModel
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading) {
            ScrollView {
                Text(model.terminalLines.joined(separator: "\n"))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                TextField("ATRV, STDI, ATSH 7E4, 22 48 45 …", text: $input)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { send() }
                Button("Send", action: send)
            }
        }
        .padding()
    }

    private func send() {
        let c = input.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return }
        model.sendTerminal(c)
        input = ""
    }
}

struct ForscanHelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Running FORScan itself on a Mac").font(.title2.bold())
                Text("FORScan is closed-source Windows software, so it can't be ported. FordLink covers adapter setup, module discovery, codes and Mach-E battery data natively. For module configuration (As-Built edits, service procedures, programming), run the real FORScan:")
                Group {
                    Text("1. Recommended — Windows 11 ARM in Parallels Desktop or VMware Fusion (Apple Silicon) or Windows x64 VM (Intel). Pass the OBDLink EX USB device through to the VM. Most reliable; FORScan's own recommended route.").fixedSize(horizontal: false, vertical: true)
                    Text("2. CrossOver / Wine — `scripts/forscan-wine.sh` installs FORScan into a Wine prefix and maps COM1 to your adapter's /dev/cu.* port. Good for reading/live data; avoid module programming under Wine.").fixedSize(horizontal: false, vertical: true)
                }
                Text("Before any configuration or programming: 12V maintainer connected, Mach-E in 'Ready' or ignition-on, laptop on power, Wi-Fi/Bluetooth adapters not used for programming (USB only).")
                    .foregroundStyle(.orange)
                Text("Full guide: docs/FORSCAN_ON_MAC.md in the repository.").foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: 700, alignment: .leading)
        }
    }
}
#endif
