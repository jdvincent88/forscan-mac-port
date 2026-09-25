import Foundation

#if canImport(CoreBluetooth)
import CoreBluetooth

/// Bluetooth Low Energy transport for BLE OBD adapters (OBDLink CX, vLinker FS/MC BLE, Vgate iCar Pro BLE).
///
/// Classic-Bluetooth (SPP) adapters such as OBDLink MX+ are *not* BLE: pair them in macOS
/// System Settings and they appear as a `/dev/cu.*` serial port — use `SerialTransport`.
///
/// This transport scans for a peripheral whose name contains `nameOrUUID` (or whose identifier
/// equals it), then picks the first characteristic with notify/indicate for RX and the first with
/// write/writeWithoutResponse for TX. That generic approach covers the common FFF0/FFE0 UART-style
/// services used by most BLE ELM327 designs.
public final class BLETransport: NSObject, Transport, CBCentralManagerDelegate, CBPeripheralDelegate {
    public let nameOrUUID: String
    public var name: String { "BLE \(peripheral?.name ?? nameOrUUID)" }
    public var isOpen: Bool { rx != nil && tx != nil && peripheral?.state == .connected }

    private let queue = DispatchQueue(label: "fordlink.ble")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var tx: CBCharacteristic?
    private var buffer = Data()
    private let lock = NSCondition()
    private let ready = DispatchSemaphore(value: 0)
    private var failure: String?

    public init(nameOrUUID: String) {
        self.nameOrUUID = nameOrUUID
        super.init()
    }

    public func open() throws {
        if isOpen { return }
        failure = nil
        central = CBCentralManager(delegate: self, queue: queue)
        if ready.wait(timeout: .now() + 20) == .timedOut {
            central.stopScan()
            throw TransportError.openFailed("BLE adapter '\(nameOrUUID)' not found or did not expose UART characteristics")
        }
        if let f = failure { throw TransportError.openFailed(f) }
    }

    public func close() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil; rx = nil; tx = nil
    }

    public func write(_ data: Data) throws {
        guard isOpen, let p = peripheral, let tx else { throw TransportError.notOpen }
        let type: CBCharacteristicWriteType = tx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let mtu = max(20, p.maximumWriteValueLength(for: type))
        var i = 0
        while i < data.count {
            let chunk = data.subdata(in: i..<min(i + mtu, data.count))
            p.writeValue(chunk, for: tx, type: type)
            i += mtu
        }
    }

    public func read(timeout: TimeInterval) throws -> Data {
        guard isOpen else { throw TransportError.notOpen }
        lock.lock(); defer { lock.unlock() }
        if buffer.isEmpty { _ = lock.wait(until: Date().addingTimeInterval(timeout)) }
        let out = buffer
        buffer.removeAll()
        return out
    }

    // MARK: CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: c.scanForPeripherals(withServices: nil)
        case .unauthorized: failure = "Bluetooth permission denied (System Settings › Privacy & Security › Bluetooth)"; ready.signal()
        case .poweredOff: failure = "Bluetooth is turned off"; ready.signal()
        case .unsupported: failure = "Bluetooth LE unsupported on this Mac"; ready.signal()
        default: break
        }
    }

    public func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                               advertisementData: [String: Any], rssi: NSNumber) {
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        let match = p.identifier.uuidString.caseInsensitiveCompare(nameOrUUID) == .orderedSame
            || advName.localizedCaseInsensitiveContains(nameOrUUID)
        guard match else { return }
        c.stopScan()
        peripheral = p
        p.delegate = self
        c.connect(p)
    }

    public func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices(nil)
    }

    public func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        failure = "BLE connect failed: \(error?.localizedDescription ?? "unknown")"
        ready.signal()
    }

    // MARK: CBPeripheralDelegate

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if rx == nil, ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                rx = ch
                p.setNotifyValue(true, for: ch)
            }
            if tx == nil, ch.properties.contains(.write) || ch.properties.contains(.writeWithoutResponse) {
                tx = ch
            }
        }
        if rx != nil && tx != nil { ready.signal() }
    }

    public func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let v = ch.value else { return }
        lock.lock()
        buffer.append(v)
        lock.signal()
        lock.unlock()
    }
}

func makeBLETransport(nameOrUUID: String) -> Transport { BLETransport(nameOrUUID: nameOrUUID) }

#else

/// Placeholder on platforms without CoreBluetooth.
public final class UnsupportedBLETransport: Transport {
    public let name: String
    public var isOpen: Bool { false }
    init(_ n: String) { name = "BLE \(n)" }
    public func open() throws { throw TransportError.openFailed("Bluetooth LE requires macOS") }
    public func close() {}
    public func write(_ data: Data) throws { throw TransportError.notOpen }
    public func read(timeout: TimeInterval) throws -> Data { throw TransportError.notOpen }
}

func makeBLETransport(nameOrUUID: String) -> Transport { UnsupportedBLETransport(nameOrUUID) }

#endif
