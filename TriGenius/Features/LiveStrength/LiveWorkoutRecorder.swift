#if os(iOS)
import CoreBluetooth
import HealthKit

// MARK: - Live workout recorder
//
// The Apple Health workout behind a live strength session. Its running
// `HKWorkoutSession` keeps the app alive in the background, so rests, holds
// and their haptics carry on with the phone locked, and collects heart rate
// from the sensors HealthKit drives itself (AirPods). A Bluetooth sensor — a
// chest strap, a Garmin watch broadcasting heart rate — HealthKit never picks
// up, so `HeartRateSensor` reads it alongside; its readings join the workout
// only when HealthKit collected none, so AirPods win and the two never double
// up. The saved workout is what `DataSyncCoordinator.saveLiveStrength` reads
// the heart rate back from.

final class LiveWorkoutRecorder: NSObject {
    private let store = HKHealthStore()
    private let sensor = HeartRateSensor()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var starting: Task<Void, Never>?
    /// HealthKit's own latest reading, stamped when it arrived.
    private var collected: HeartRateSensor.Reading?

    private nonisolated static let heartRate = HKQuantityType(.heartRate)
    private nonisolated static let bpm = HKUnit.count().unitDivided(by: .minute())
    /// How long a reading still shows as the current heart rate.
    private static let currentFor: TimeInterval = 10

    init(start: Date) {
        super.init()
        starting = Task { try? await begin(at: start) }
    }

    /// The heart rate to show at `date`, by the same precedence as the saved
    /// workout: HealthKit's own while it is current, else the Bluetooth sensor's.
    func heartRate(at date: Date) -> Int? {
        func current(_ reading: HeartRateSensor.Reading?) -> Int? {
            reading.flatMap { date.timeIntervalSince($0.date) < Self.currentFor ? Int($0.bpm.rounded()) : nil }
        }
        return current(collected) ?? current(sensor.readings.last)
    }

    private func begin(at start: Date) async throws {
        let config = HKWorkoutConfiguration()
        config.activityType = .traditionalStrengthTraining
        config.locationType = .indoor
        try await store.requestAuthorization(toShare: [.workoutType(), Self.heartRate], read: [Self.heartRate])
        let session = try HKWorkoutSession(healthStore: store, configuration: config)
        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
        builder.delegate = self
        self.session = session
        self.builder = builder
        session.startActivity(with: start)
        try await builder.beginCollection(at: start)
    }

    /// Ends the workout at `end` and saves it to Apple Health; nil when it never ran.
    func finish(at end: Date) async -> HKWorkout? {
        await starting?.value
        sensor.stop()
        guard let session, let builder else { return nil }
        session.end()
        let readings = sensor.readings.filter { $0.date <= end }
        do {
            if builder.statistics(for: Self.heartRate) == nil, !readings.isEmpty {
                try await builder.addSamples(readings.map {
                    HKQuantitySample(type: Self.heartRate, quantity: HKQuantity(unit: Self.bpm, doubleValue: $0.bpm),
                                     start: $0.date, end: $0.date)
                })
            }
            try await builder.endCollection(at: end)
            return try await builder.finishWorkout()
        } catch {
            return nil
        }
    }

    func discard() {
        sensor.stop()
        Task {
            await starting?.value
            session?.end()
            builder?.discardWorkout()
        }
    }
}

extension LiveWorkoutRecorder: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard collectedTypes.contains(Self.heartRate),
              let bpm = workoutBuilder.statistics(for: Self.heartRate)?.mostRecentQuantity()?
                .doubleValue(for: Self.bpm) else { return }
        Task { @MainActor in self.collected = (.now, bpm) }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

// MARK: - Bluetooth heart-rate sensor

/// The first Bluetooth heart-rate sensor (GATT service 0x180D) in range, one
/// reading per notification (≈ 1 Hz). A dropped connection scans again.
final class HeartRateSensor: NSObject {
    typealias Reading = (date: Date, bpm: Double)

    private(set) var readings: [Reading] = []
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?

    private static let service = CBUUID(string: "180D")
    private static let measurement = CBUUID(string: "2A37")

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func stop() {
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        central?.stopScan()
        central = nil
        peripheral = nil
    }
}

extension HeartRateSensor: @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        if let connected = central.retrieveConnectedPeripherals(withServices: [Self.service]).first {
            connect(connected)
        } else {
            central.scanForPeripherals(withServices: [Self.service])
        }
    }

    private func connect(_ peripheral: CBPeripheral) {
        central?.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central?.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if self.peripheral == nil { connect(peripheral) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        rescan(central)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        rescan(central)
    }

    /// After a lost sensor — but not once `stop` has let the manager go.
    private func rescan(_ central: CBCentralManager) {
        guard self.central != nil else { return }
        peripheral = nil
        central.scanForPeripherals(withServices: [Self.service])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        for service in peripheral.services ?? [] where service.uuid == Self.service {
            peripheral.discoverCharacteristics([Self.measurement], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        for characteristic in service.characteristics ?? [] where characteristic.uuid == Self.measurement {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    /// Heart Rate Measurement: flag bit 0 selects a UInt8 or a little-endian UInt16 value.
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard let bytes = characteristic.value.map(Array.init), let flags = bytes.first else { return }
        let wide = flags & 1 == 1
        guard bytes.count >= (wide ? 3 : 2) else { return }
        let bpm = wide ? Int(bytes[1]) | Int(bytes[2]) << 8 : Int(bytes[1])
        if bpm > 0 { readings.append((.now, Double(bpm))) }
    }
}
#endif
