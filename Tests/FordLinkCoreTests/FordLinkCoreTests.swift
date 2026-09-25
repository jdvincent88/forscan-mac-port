import XCTest
@testable import FordLinkCore

final class ParsingTests: XCTestCase {
    func testHexRoundTrip() {
        XCTAssertEqual(Hex.bytes("22 48 01"), [0x22, 0x48, 0x01])
        XCTAssertEqual(Hex.bytes("224801"), [0x22, 0x48, 0x01])
        XCTAssertNil(Hex.bytes("22480"))
        XCTAssertEqual(Hex.id(0x7E4), "7E4")
        XCTAssertEqual(Hex.id(0x18DAF110), "18DAF110")
    }

    func testFrameParsing() {
        XCTAssertEqual(CANFrame.parse(line: "7EC 05 62 48 01 9D 40 00 00"),
                       CANFrame(id: 0x7EC, data: [0x05, 0x62, 0x48, 0x01, 0x9D, 0x40, 0x00, 0x00]))
        XCTAssertEqual(CANFrame.parse(line: "7EC0562480100")?.id, 0x7EC)
        XCTAssertEqual(CANFrame.parse(line: "18 DA F1 10 03 41 0D 00")?.id, 0x18DAF110)
        XCTAssertNil(CANFrame.parse(line: "NO DATA"))
        XCTAssertNil(CANFrame.parse(line: "OK"))
        XCTAssertNil(CANFrame.parse(line: "SEARCHING..."))
    }

    func testISOTPMultiFrame() {
        var a = ISOTPAssembler()
        for l in ["7EC 10 14 62 F1 90 33 46 4D", "7EC 21 54 4B 33 53 55 35 4D", "7EC 22 4D 41 31 32 33 34 35"] {
            a.feed(CANFrame.parse(line: l)!)
        }
        XCTAssertEqual(a.messages.count, 1)
        XCTAssertEqual(a.messages[0].payload.count, 0x14)
        XCTAssertEqual(String(decoding: a.messages[0].payload.dropFirst(3), as: UTF8.self), "3FMTK3SU5MMA12345")
    }

    func testISOTPDropsOutOfOrder() {
        var a = ISOTPAssembler()
        a.feed(CANFrame(id: 0x7E8, data: [0x10, 0x0A, 1, 2, 3, 4, 5, 6]))
        a.feed(CANFrame(id: 0x7E8, data: [0x22, 7, 8, 9, 10]))
        XCTAssertTrue(a.messages.isEmpty)
    }

    func testDTCFormatting() {
        XCTAssertEqual(DTC.format(0x0A, 0x7F, 0x00), "P0A7F-00")
        XCTAssertEqual(DTC.format(0xC1, 0x00, 0x00), "U0100-00")
        XCTAssertEqual(DTC.format(0x9A, 0x03, 0x11), "B1A03-11")
        XCTAssertEqual(DTC.format(0x42, 0x00, nil), "C0200")
        let d = UDSClient.parseDTCs([0x59, 0x02, 0xFF, 0x0A, 0x7F, 0x00, 0x08, 0xC1, 0x00, 0x00, 0x09])
        XCTAssertEqual(d.map(\.code), ["P0A7F-00", "U0100-00"])
        XCTAssertEqual(d[1].flags, ["failed now", "confirmed"])
    }

    func testEndpointParsing() {
        XCTAssertEqual(AdapterEndpoint.parse("/dev/cu.usbserial-A1"), .serial(path: "/dev/cu.usbserial-A1", baud: 0))
        XCTAssertEqual(AdapterEndpoint.parse("/dev/cu.x@115200"), .serial(path: "/dev/cu.x", baud: 115200))
        XCTAssertEqual(AdapterEndpoint.parse("wifi"), .tcp(host: "192.168.0.10", port: 35000))
        XCTAssertEqual(AdapterEndpoint.parse("tcp:10.0.0.5:23"), .tcp(host: "10.0.0.5", port: 23))
        XCTAssertEqual(AdapterEndpoint.parse("ble:OBDLink CX"), .bluetoothLE(nameOrUUID: "OBDLink CX"))
        XCTAssertEqual(AdapterEndpoint.parse("sim:mache-clone"), .simulator(.machEClone))
        XCTAssertNil(AdapterEndpoint.parse("COM3"))
    }

    func testVIN() {
        XCTAssertTrue(VIN.isMachE("3FMTK3SU5MMA12345"))
        XCTAssertFalse(VIN.isMachE("1FA6P8CF5M5100001"))
        XCTAssertEqual(VIN.modelYear("3FMTK3SU5MMA12345"), 2021)
        XCTAssertEqual(VIN.modelYear("3FMTK3SU5PMA12345"), 2023)
        XCTAssertFalse(VIN.isValid("3FMTK3SU5MMA1234O"))
    }
}

final class SimulatorIntegrationTests: XCTestCase {
    func testMachESetupWithOBDLink() throws {
        let rep = try AdapterSetup(endpoint: .simulator(.machE)).run()
        XCTAssertEqual(rep.adapterClass, .stnWithMSCAN)
        XCTAssertEqual(rep.vin, "3FMTK3SU5MMA12345")
        XCTAssertTrue(rep.isMachE)
        XCTAssertEqual(rep.buses[FordBus.hsCAN.rawValue]?.contains("7E4"), true)
        XCTAssertEqual(rep.buses[FordBus.hsCANPins3_11.rawValue]?.contains("726"), true)
    }

    func testCloneIsDowngraded() throws {
        let rep = try AdapterSetup(endpoint: .simulator(.machEClone)).run()
        XCTAssertEqual(rep.adapterClass, .poorClone)
        XCTAssertEqual(rep.usableBuses, [.hsCAN])
    }

    func testNoVehicleWarns() throws {
        let rep = try AdapterSetup(endpoint: .simulator(.noVehicle)).run()
        XCTAssertNil(rep.vin)
        XCTAssertTrue(rep.warnings.contains { $0.contains("No modules answered") })
    }

    func testLiveDataDecoding() throws {
        let (elm, _) = try AdapterSetup(endpoint: .simulator(.machE)).connect()
        let readings = LiveDataReader(uds: UDSClient(elm: elm)).read(MachEPIDs.all)
        func v(_ n: String) -> Double? { readings.first { $0.pid.name == n }?.value }
        XCTAssertEqual(v("HV battery SoC (raw)")!, 78.4, accuracy: 0.01)
        XCTAssertEqual(v("HV battery SoC (displayed)")!, 80, accuracy: 0.01)
        XCTAssertEqual(v("HV battery voltage")!, 360, accuracy: 0.01)
        XCTAssertEqual(v("HV battery current")!, -5, accuracy: 0.01)
        XCTAssertEqual(v("HV battery temperature")!, 75.2, accuracy: 0.01)
        XCTAssertEqual(LiveDataReader.batteryPowerKW(readings)!, -1.8, accuracy: 0.001)
    }

    func testResponsePendingIsHandled() throws {
        let sim = VehicleSimulator(profile: .machE)
        sim.pendingFirst = [0x7E4]
        let elm = ELM327(transport: sim)
        try sim.open()
        try elm.reset()
        let b = try UDSClient(elm: elm).readDID(module: 0x7E4, bus: .hsCAN, did: 0x4845)
        XCTAssertEqual(b, [160])
    }

    func testNegativeResponse() throws {
        let (elm, _) = try AdapterSetup(endpoint: .simulator(.machE)).connect()
        XCTAssertThrowsError(try UDSClient(elm: elm).readDID(module: 0x7E4, bus: .hsCAN, did: 0x1234)) { e in
            XCTAssertEqual(e as? UDSError, .negativeResponse(service: 0x22, code: 0x31))
        }
    }

    func testModuleScanFindsBothBuses() throws {
        let setup = AdapterSetup(endpoint: .simulator(.machE))
        let (elm, _) = try setup.connect()
        let found = ModuleScanner(uds: UDSClient(elm: elm)).scan(buses: FordBus.allCases, machE: true)
        XCTAssertEqual(Set(found.map(\.requestID)), [0x7E4, 0x7E2, 0x7E0, 0x760, 0x716, 0x726, 0x720])
        XCTAssertEqual(found.first { $0.requestID == 0x7E4 }?.partNumber, "NU5T-14C197-AB")
    }
}
