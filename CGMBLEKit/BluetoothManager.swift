//
//  BluetoothManager.swift
//  xDripG5
//
//  Created by Nathan Racklyeft on 10/1/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import CoreBluetooth
import Foundation
import os.log


#if LIVE_READ_ONLY
/// Sanitized, in-memory observer diagnostics. Counters are cumulative for this
/// transmitter instance, not glucose data or evidence of a successful reading.
public struct ResearchConnectionDiagnostics {
    public enum CentralState: String {
        case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn
    }
    public enum ConnectionStage: String {
        case idle, paused, bluetoothUnavailable, waitingForDelegate
        case noSystemConnection, noMatchingConnection, connecting, connected
        case disconnected, connectionFailed
    }
    public internal(set) var centralState: CentralState = .unknown
    public internal(set) var connectionStage: ConnectionStage = .idle
    public internal(set) var connectionEventsRegistered = false
    public internal(set) var connectionEvents = 0
    public internal(set) var restorationEvents = 0
    public internal(set) var restoredAttachments = 0
    public internal(set) var systemQueries = 0
    public internal(set) var lastCandidateCount = 0
    public internal(set) var lastMatchCount = 0
    public internal(set) var connectionCount = 0
    public internal(set) var authenticationSubscriptionAttempts = 0
    public internal(set) var authenticationSubscriptionSuccesses = 0
    public internal(set) var authenticationNotifications = 0
    public internal(set) var authenticationAccepted = 0
    public internal(set) var controlSubscriptionAttempts = 0
    public internal(set) var controlSubscriptionSuccesses = 0
    public internal(set) var controlNotifications = 0
    public internal(set) var timeObserved = false
    public internal(set) var glucoseMessages = 0
    public internal(set) var decodedGlucosePackets = 0
    public internal(set) var invalidGlucosePackets = 0
    public internal(set) var awaitingTimePackets = 0
    public internal(set) var invalidTimePackets = 0
    public internal(set) var untimedPacketsDropped = 0
    public internal(set) var clockReferencesDropped = 0

    public var summary: String {
        return "Connection diagnostics v1\n" +
            "Bluetooth: \(centralState.rawValue); stage: \(connectionStage.rawValue)\n" +
            "System event registration: \(connectionEventsRegistered); events: \(connectionEvents); restorations: \(restorationEvents); attached: \(restoredAttachments)\n" +
            "System queries: \(systemQueries); last candidates: \(lastCandidateCount); matches: \(lastMatchCount); connections: \(connectionCount)\n" +
            "Auth subscriptions: \(authenticationSubscriptionSuccesses)/\(authenticationSubscriptionAttempts); notifications: \(authenticationNotifications); accepted: \(authenticationAccepted)\n" +
            "Control subscriptions: \(controlSubscriptionSuccesses)/\(controlSubscriptionAttempts); notifications: \(controlNotifications); time observed: \(timeObserved); glucose messages: \(glucoseMessages)\n" +
            "Decoded: \(decodedGlucosePackets); invalid glucose: \(invalidGlucosePackets); awaiting time: \(awaitingTimePackets); invalid time: \(invalidTimePackets); dropped untimed/clock: \(untimedPacketsDropped)/\(clockReferencesDropped)\n" +
            "Counters are cumulative, not readings."
    }
}
#endif

#if LIVE_READ_ONLY
/// Connection notifications are hints, never permission to connect a cached peer.
enum ResearchConnectionRecovery {
    static func onEvent(enabled: Bool, peerConnected: Bool, lookup: () -> Void) {
        guard enabled, peerConnected else { return }
        lookup()
    }
    static func restoredCandidate<Peer>(enabled: Bool, poweredOn: Bool, restoredIDs: Set<UUID>,
        systemConnected: [Peer], id: (Peer) -> UUID, matches: (Peer) -> Bool,
        locallyConnected: (Peer) -> Bool) -> Peer? {
        guard enabled, poweredOn else { return nil }
        return systemConnected.first { restoredIDs.contains(id($0)) && matches($0) && locallyConnected($0) }
    }
}
#endif


protocol BluetoothManagerDelegate: AnyObject {
    #if LIVE_READ_ONLY
    func bluetoothManagerDidUpdateResearchConnection(_ manager: BluetoothManager)
    #endif

    /**
     Tells the delegate that the bluetooth manager has finished connecting to and discovering all required services of its peripheral, or that it failed to do so

     - parameter manager: The bluetooth manager
     - parameter peripheralManager: The peripheral manager
     - parameter error:   An error describing why bluetooth setup failed
     */
    func bluetoothManager(_ manager: BluetoothManager, peripheralManager: PeripheralManager, isReadyWithError error: Error?)

    /**
     Asks the delegate whether the discovered or restored peripheral should be connected

     - parameter manager:    The bluetooth manager
     - parameter peripheral: The found peripheral

     - returns: True if the peripheral should connect
     */
    func bluetoothManager(_ manager: BluetoothManager, shouldConnectPeripheral peripheral: CBPeripheral) -> Bool

    /// Informs the delegate that the bluetooth manager received new data in the control characteristic
    ///
    /// - Parameters:
    ///   - manager: The bluetooth manager
    ///   - peripheralManager: The peripheral manager
    ///   - response: The data received on the control characteristic
    func bluetoothManager(_ manager: BluetoothManager, peripheralManager: PeripheralManager, didReceiveControlResponse response: Data)

    /// Informs the delegate that the bluetooth manager received new data in the backfill characteristic
    ///
    /// - Parameters:
    ///   - manager: The bluetooth manager
    ///   - response: The data received on the backfill characteristic
    func bluetoothManager(_ manager: BluetoothManager, didReceiveBackfillResponse response: Data)

    /// Informs the delegate that the bluetooth manager received new data in the authentication characteristic
    ///
    /// - Parameters:
    ///   - manager: The bluetooth manager
    ///   - peripheralManager: The peripheral manager
    ///   - response: The data received on the authentication characteristic
    func bluetoothManager(_ manager: BluetoothManager, peripheralManager: PeripheralManager, didReceiveAuthenticationResponse response: Data)
}


class BluetoothManager: NSObject {

    var stayConnected: Bool {
        get {
            return lockedStayConnected.value
        }
        set {
            lockedStayConnected.value = newValue
            #if LIVE_READ_ONLY
            if !newValue { updateResearchDiagnostics { $0.connectionStage = .paused } }
            managerQueue.async {
                self.managerQueue_updateEventRegistration()
                if newValue { self.managerQueue_scanForPeripheral() }
            }
            #endif
        }
    }
    #if LIVE_READ_ONLY
    private let lockedStayConnected: Locked<Bool> = Locked(false)
    private var restoredPeripherals: [CBPeripheral] = [] // managerQueue only
    private var eventsRegistered = false
    #else
    private let lockedStayConnected: Locked<Bool> = Locked(true)
    #endif

    #if LIVE_READ_ONLY
    private let lockedResearchDiagnostics = Locked(ResearchConnectionDiagnostics())
    var researchConnectionDiagnostics: ResearchConnectionDiagnostics { lockedResearchDiagnostics.value }
    func updateResearchDiagnostics(_ changes: (inout ResearchConnectionDiagnostics) -> Void) {
        _ = lockedResearchDiagnostics.mutate(changes)
    }
    #endif

    weak var delegate: BluetoothManagerDelegate? {
        didSet {
            #if LIVE_READ_ONLY
            managerQueue.async {
                self.managerQueue_updateEventRegistration()
                self.managerQueue_scanForPeripheral()
            }
            #endif
        }
    }

    private let log = OSLog(category: "BluetoothManager")

    /// Isolated to `managerQueue`
    private var manager: CBCentralManager! = nil

    /// Isolated to `managerQueue`
    private var peripheral: CBPeripheral? {
        get {
            return peripheralManager?.peripheral
        }
        set {
            guard let peripheral = newValue else {
                peripheralManager = nil
                return
            }

            if let peripheralManager = peripheralManager {
                peripheralManager.peripheral = peripheral
            } else {
                peripheralManager = PeripheralManager(
                    peripheral: peripheral,
                    configuration: .dexcomG5,
                    centralManager: manager
                )
            }
        }
    }

    var peripheralIdentifier: UUID? {
        get {
            return lockedPeripheralIdentifier.value
        }
        set {
            lockedPeripheralIdentifier.value = newValue
        }
    }
    private let lockedPeripheralIdentifier: Locked<UUID?> = Locked(nil)

    /// Isolated to `managerQueue`
    private var peripheralManager: PeripheralManager? {
        didSet {
            oldValue?.delegate = nil
            peripheralManager?.delegate = self

            peripheralIdentifier = peripheralManager?.peripheral.identifier
        }
    }

    // MARK: - Synchronization

    private let managerQueue = DispatchQueue(label: "com.loudnate.CGMBLEKit.bluetoothManagerQueue", qos: .unspecified)

    override init() {
        super.init()

        managerQueue.sync {
            #if LIVE_READ_ONLY
            self.manager = CBCentralManager(delegate: self, queue: managerQueue, options: [CBCentralManagerOptionRestoreIdentifierKey: "org.projectlive.loop.g6research"])
            #else
            self.manager = CBCentralManager(delegate: self, queue: managerQueue, options: [CBCentralManagerOptionRestoreIdentifierKey: "com.loudnate.CGMBLEKit"])
            #endif
        }
    }

    // MARK: - Actions

    func scanForPeripheral() {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        managerQueue.sync {
            self.managerQueue_scanForPeripheral()
        }
    }

    func disconnect() {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        managerQueue.sync {
            if manager.isScanning {
                manager.stopScan()
            }

            if let peripheral = peripheral {
                manager.cancelPeripheralConnection(peripheral)
            }
            #if LIVE_READ_ONLY
            for restored in restoredPeripherals where restored.identifier != peripheral?.identifier {
                manager.cancelPeripheralConnection(restored)
            }
            restoredPeripherals.removeAll()
            managerQueue_updateEventRegistration()
            #endif
        }
    }

    #if LIVE_READ_ONLY
    private func managerQueue_updateEventRegistration() {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        guard manager.state == .poweredOn else { eventsRegistered = false; return }
        let enabled = stayConnected && delegate != nil
        guard enabled != eventsRegistered else { return }
        manager.registerForConnectionEvents(options: enabled ? [.serviceUUIDs: [TransmitterServiceUUID.advertisement.cbUUID, TransmitterServiceUUID.cgmService.cbUUID]] : nil)
        eventsRegistered = enabled
        updateResearchDiagnostics { $0.connectionEventsRegistered = enabled }
    }
    #endif

    private func managerQueue_scanForPeripheral() {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        #if LIVE_READ_ONLY
        guard stayConnected else { return }
        #endif

        guard manager.state == .poweredOn else {
            #if LIVE_READ_ONLY
            updateResearchDiagnostics { $0.connectionStage = .bluetoothUnavailable }
            #endif
            return
        }

        let currentState = peripheral?.state ?? .disconnected
        guard currentState != .connected else {
            return
        }

        #if LIVE_READ_ONLY
        // Foreground polling must not enqueue duplicate local connection requests.
        guard currentState != .connecting else { return }
        // Share only a connection already owned by iOS/the existing G6 app.
        // No scan, known-device reconnect, or application authentication fallback.
        guard let delegate = delegate else {
            updateResearchDiagnostics { $0.connectionStage = .waitingForDelegate }
            return
        }
        let connected = manager.retrieveConnectedPeripherals(withServices: [TransmitterServiceUUID.advertisement.cbUUID, TransmitterServiceUUID.cgmService.cbUUID])
        let matching = connected.filter { delegate.bluetoothManager(self, shouldConnectPeripheral: $0) }
        updateResearchDiagnostics {
            $0.systemQueries += 1
            $0.lastCandidateCount = connected.count
            $0.lastMatchCount = matching.count
            $0.connectionStage = connected.isEmpty ? .noSystemConnection : .noMatchingConnection
        }
        if let restored = ResearchConnectionRecovery.restoredCandidate(enabled: stayConnected,
            poweredOn: manager.state == .poweredOn,
            restoredIDs: Set(restoredPeripherals.map { $0.identifier }),
            systemConnected: connected, id: { $0.identifier },
            matches: { delegate.bluetoothManager(self, shouldConnectPeripheral: $0) },
            locallyConnected: { $0.state == .connected }) {
            self.peripheral = restored // rebind CBPeripheralDelegate before handling notifications
            restoredPeripherals.removeAll()
            updateResearchDiagnostics { $0.restoredAttachments += 1; $0.connectionStage = .connected }
            if let peripheralManager { delegate.bluetoothManager(self, peripheralManager: peripheralManager, isReadyWithError: nil) }
            return
        }
        guard let candidate = matching.first else { return }
        self.peripheral = candidate
        updateResearchDiagnostics { $0.connectionStage = .connecting }
        manager.connect(candidate)
        #else
        if let peripheralID = peripheralIdentifier, let peripheral = manager.retrievePeripherals(withIdentifiers: [peripheralID]).first {
            log.debug("Re-connecting to known peripheral %{public}@", peripheral.identifier.uuidString)
            self.peripheral = peripheral
            self.manager.connect(peripheral)
        } else if let peripheral = manager.retrieveConnectedPeripherals(withServices: [
                TransmitterServiceUUID.advertisement.cbUUID,
                TransmitterServiceUUID.cgmService.cbUUID
            ]).first,
            delegate == nil || delegate!.bluetoothManager(self, shouldConnectPeripheral: peripheral)
        {
            log.debug("Found system-connected peripheral: %{public}@", peripheral.identifier.uuidString)
            self.peripheral = peripheral
            self.manager.connect(peripheral)
        } else {
            log.debug("Scanning for peripherals")
            manager.scanForPeripherals(withServices: [
                    TransmitterServiceUUID.advertisement.cbUUID
                ],
                options: nil
            )
        }
        #endif
    }

    /**
    
     Persistent connections don't seem to work with the transmitter shutoff: The OS won't re-wake the
     app unless it's scanning.
     
     The sleep gives the transmitter time to shut down, but keeps the app running.

     */
    fileprivate func scanAfterDelay() {
        #if LIVE_READ_ONLY
        // Do not sleep through the short background execution window. Future
        // connection events trigger fresh system-connected lookup without a timer.
        managerQueue.async { self.managerQueue_scanForPeripheral() }
        #else
        DispatchQueue.global(qos: .utility).async {
            Thread.sleep(forTimeInterval: 2)

            self.scanForPeripheral()
        }
        #endif
    }

    // MARK: - Accessors

    var isScanning: Bool {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        var isScanning = false
        managerQueue.sync {
            isScanning = manager.isScanning
        }
        return isScanning
    }

    override var debugDescription: String {
        return [
            "## BluetoothManager",
            peripheralManager.map(String.init(reflecting:)) ?? "No peripheral",
        ].joined(separator: "\n")
    }
}


extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        #if LIVE_READ_ONLY
        updateResearchDiagnostics {
            switch central.state {
            case .unknown: $0.centralState = .unknown
            case .resetting: $0.centralState = .resetting
            case .unsupported: $0.centralState = .unsupported
            case .unauthorized: $0.centralState = .unauthorized
            case .poweredOff: $0.centralState = .poweredOff
            case .poweredOn: $0.centralState = .poweredOn
            @unknown default: $0.centralState = .unknown
            }
        }
        #endif
        peripheralManager?.centralManagerDidUpdateState(central)
        log.default("%{public}@: %{public}@", #function, String(describing: central.state.rawValue))

        switch central.state {
        case .poweredOn:
            #if LIVE_READ_ONLY
            managerQueue_updateEventRegistration()
            #endif
            managerQueue_scanForPeripheral()
        case .resetting, .poweredOff, .unauthorized, .unknown, .unsupported:
            fallthrough
        @unknown default:
            #if LIVE_READ_ONLY
            eventsRegistered = false
            updateResearchDiagnostics { $0.connectionEventsRegistered = false }
            #endif
            if central.isScanning {
                central.stopScan()
            }
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        #if LIVE_READ_ONLY
        // This callback can precede poweredOn, delegate assignment and consent
        // activation. Retain OS-owned handles until all gates are satisfied.
        restoredPeripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        updateResearchDiagnostics { $0.restorationEvents += 1 }
        managerQueue_updateEventRegistration()
        managerQueue_scanForPeripheral()
        return
        #else
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in peripherals {
                if delegate == nil || delegate!.bluetoothManager(self, shouldConnectPeripheral: peripheral) {
                    log.default("Restoring peripheral from state: %{public}@", peripheral.identifier.uuidString)
                    self.peripheral = peripheral
                }
            }
        }
        #endif
    }

    #if LIVE_READ_ONLY
    func centralManager(_ central: CBCentralManager, connectionEventDidOccur event: CBConnectionEvent, for peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        updateResearchDiagnostics { $0.connectionEvents += 1 }
        ResearchConnectionRecovery.onEvent(enabled: stayConnected, peerConnected: event == .peerConnected) {
            // Never connect directly from a callback or cached UUID. The existing
            // fresh lookup, configured-name match and pending-connect guard apply.
            self.managerQueue_scanForPeripheral()
        }
        delegate?.bluetoothManagerDidUpdateResearchConnection(self)
    }
    #endif

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        #if LIVE_READ_ONLY
        // Never adopt newly discovered devices in the research configuration.
        return
        #else
        log.info("%{public}@: %{public}@", #function, peripheral)
        if delegate == nil || delegate!.bluetoothManager(self, shouldConnectPeripheral: peripheral) {
            self.peripheral = peripheral

            central.connect(peripheral, options: nil)

            central.stopScan()
        }
        #endif
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        #if LIVE_READ_ONLY
        guard stayConnected else { central.cancelPeripheralConnection(peripheral); return }
        updateResearchDiagnostics {
            $0.connectionStage = .connected
            $0.connectionCount += 1
        }
        #endif

        log.default("%{public}@: %{public}@", #function, peripheral)
        if central.isScanning {
            central.stopScan()
        }

        peripheralManager?.centralManager(central, didConnect: peripheral)

        if case .poweredOn = manager.state, case .connected = peripheral.state, let peripheralManager = peripheralManager {
            self.delegate?.bluetoothManager(self, peripheralManager: peripheralManager, isReadyWithError: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        #if LIVE_READ_ONLY
        updateResearchDiagnostics { $0.connectionStage = stayConnected ? .disconnected : .paused }
        #endif
        log.default("%{public}@: %{public}@", #function, peripheral)
        // Ignore errors indicating the peripheral disconnected remotely, as that's expected behavior
        if let error = error as NSError?, CBError(_nsError: error).code != .peripheralDisconnected {
            log.error("%{public}@: %{public}@", #function, error)
            if let peripheralManager = peripheralManager {
                self.delegate?.bluetoothManager(self, peripheralManager: peripheralManager, isReadyWithError: error)
            }
        }

        if stayConnected {
            scanAfterDelay()
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        #if LIVE_READ_ONLY
        updateResearchDiagnostics { $0.connectionStage = stayConnected ? .connectionFailed : .paused }
        #endif

        log.error("%{public}@: %{public}@", #function, String(describing: error))
        if let error = error, let peripheralManager = peripheralManager {
            self.delegate?.bluetoothManager(self, peripheralManager: peripheralManager, isReadyWithError: error)
        }

        if stayConnected {
            scanAfterDelay()
        }
    }
}


extension BluetoothManager: PeripheralManagerDelegate {
    func peripheralManager(_ manager: PeripheralManager, didReadRSSI RSSI: NSNumber, error: Error?) {
        
    }

    func peripheralManagerDidUpdateName(_ manager: PeripheralManager) {

    }

    func completeConfiguration(for manager: PeripheralManager) throws {

    }

    func peripheralManager(_ manager: PeripheralManager, didUpdateValueFor characteristic: CBCharacteristic) {
        guard let value = characteristic.value else {
            return
        }

        switch CGMServiceCharacteristicUUID(rawValue: characteristic.uuid.uuidString.uppercased()) {
        case .none, .communication?:
            return
        case .control?:
            self.delegate?.bluetoothManager(self, peripheralManager: manager, didReceiveControlResponse: value)
        case .backfill?:
            self.delegate?.bluetoothManager(self, didReceiveBackfillResponse: value)
        case .authentication?:
            self.delegate?.bluetoothManager(self, peripheralManager: manager, didReceiveAuthenticationResponse: value)
        }
    }
}
