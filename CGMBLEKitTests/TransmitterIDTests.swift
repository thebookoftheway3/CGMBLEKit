//
//  TransmitterIDTests.swift
//  xDripG5Tests
//
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//

import XCTest
@testable import CGMBLEKit

class TransmitterIDTests: XCTestCase {

    /// Sanity check the hash computation path
    func testComputeHash() {
        let id = TransmitterID(id: "123456")

        XCTAssertEqual("e60d4a7999b0fbb2", id.computeHash(of: Data(hexadecimalString: "0123456789abcdef")!)!.hexadecimalString)
    }
    
}

#if LIVE_READ_ONLY
final class ResearchConnectionDiagnosticsTests: XCTestCase {
    func testDefaultSnapshotCannotRepresentPatientOrDeviceText() {
        let snapshot = ResearchConnectionDiagnostics()
        XCTAssertEqual(snapshot.centralState, .unknown)
        XCTAssertEqual(snapshot.connectionStage, .idle)
        XCTAssertEqual(snapshot.systemQueries, 0)
        XCTAssertFalse(snapshot.timeObserved)
        XCTAssertTrue(snapshot.summary.hasPrefix("Connection diagnostics v1\n"))
        for field in Mirror(reflecting: snapshot).children {
            XCTAssertTrue(field.value is Int || field.value is Bool ||
                field.value is ResearchConnectionDiagnostics.CentralState ||
                field.value is ResearchConnectionDiagnostics.ConnectionStage)
        }
    }

    func testConcurrentSnapshotsRemainCoherentAndCountersAreNotLost() {
        let state = Locked(ResearchConnectionDiagnostics())
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in
            _ = state.mutate {
                $0.authenticationSubscriptionAttempts += 1
                $0.authenticationSubscriptionSuccesses += 1
            }
            let snapshot = state.value
            XCTAssertEqual(snapshot.authenticationSubscriptionAttempts, snapshot.authenticationSubscriptionSuccesses)
        }
        XCTAssertEqual(state.value.authenticationSubscriptionAttempts, 1000)
        XCTAssertEqual(state.value.authenticationSubscriptionSuccesses, 1000)
    }
}
#endif
