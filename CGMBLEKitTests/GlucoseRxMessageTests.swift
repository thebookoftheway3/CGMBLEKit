//
//  GlucoseRxMessageTests.swift
//  xDripG5
//
//  Created by Nathan Racklyeft on 3/5/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import XCTest
@testable import CGMBLEKit


class GlucoseRxMessageTests: XCTestCase {

    func testMessageData() {
        let data = Data(hexadecimalString: "3100680a00008a715700cc0006ffc42a")!
        let message = GlucoseRxMessage(data: data)!

        XCTAssertEqual(0, message.status)
        XCTAssertEqual(2664, message.sequence)
        XCTAssertEqual(5730698, message.glucose.timestamp)
        XCTAssertFalse(message.glucose.glucoseIsDisplayOnly)
        XCTAssertEqual(204, message.glucose.glucose)
        XCTAssertEqual(6, message.glucose.state)
        XCTAssertEqual(-1, message.glucose.trend)
    }

    func testNegativeTrend() {
        let data = Data(hexadecimalString: "31006f0a0000be7957007a0006e4818d")!
        let message = GlucoseRxMessage(data: data)!

        XCTAssertEqual(0, message.status)
        XCTAssertEqual(2671, message.sequence)
        XCTAssertEqual(5732798, message.glucose.timestamp)
        XCTAssertFalse(message.glucose.glucoseIsDisplayOnly)
        XCTAssertEqual(122, message.glucose.glucose)
        XCTAssertEqual(6, message.glucose.state)
        XCTAssertEqual(-28, message.glucose.trend)
    }

    func testDisplayOnly() {
        let data = Data(hexadecimalString: "3100700a0000f17a5700584006e3cee9")!
        let message = GlucoseRxMessage(data: data)!

        XCTAssertEqual(0, message.status)
        XCTAssertEqual(2672, message.sequence)
        XCTAssertEqual(5733105, message.glucose.timestamp)
        XCTAssertTrue(message.glucose.glucoseIsDisplayOnly)
        XCTAssertEqual(88, message.glucose.glucose)
        XCTAssertEqual(6, message.glucose.state)
        XCTAssertEqual(-29, message.glucose.trend)
    }

    func testOldTransmitter() {
        let data = Data(hexadecimalString: "3100aa00000095a078008b00060a8b34")!
        let message = GlucoseRxMessage(data: data)!

        XCTAssertEqual(0, message.status)
        XCTAssertEqual(170, message.sequence)
        XCTAssertEqual(7905429, message.glucose.timestamp)  // 90 days, status is still OK
        XCTAssertFalse(message.glucose.glucoseIsDisplayOnly)
        XCTAssertEqual(139, message.glucose.glucose)
        XCTAssertEqual(6, message.glucose.state)
        XCTAssertEqual(10, message.glucose.trend)
    }

    func testZeroSequence() {
        let data = Data(hexadecimalString: "3100000000008eb14d00820006f6a038")!
        let message = GlucoseRxMessage(data: data)!

        XCTAssertEqual(0, message.status)
        XCTAssertEqual(0, message.sequence)
        XCTAssertEqual(5091726, message.glucose.timestamp)
        XCTAssertFalse(message.glucose.glucoseIsDisplayOnly)
        XCTAssertEqual(130, message.glucose.glucose)
        XCTAssertEqual(6, message.glucose.state)
        XCTAssertEqual(-10, message.glucose.trend)
    }
}

#if LIVE_READ_ONLY
final class ResearchEvidenceBufferTests: XCTestCase {
    private let glucosePacket = Data(hexadecimalString: "3100680a00008a715700cc0006ffc42a")!
    private let clockPacket = Data(hexadecimalString: "2500470272007cff710001000000fa1d")!
    private let receipt = Date(timeIntervalSince1970: 1_000_000)

    func testValidUntimedPacketPreservesOriginalReceiptAndProcessedFields() {
        var buffer = ResearchEvidenceBuffer()
        guard case .untimed = buffer.observeGlucose(glucosePacket, receivedAt: receipt, receivedUptime: 100, hasClock: false) else { return XCTFail("Missing clock must retain only untimed evidence") }
        let record = buffer.untimed[0]
        XCTAssertEqual(record.rawPacket, glucosePacket)
        XCTAssertEqual(record.receivedAt, receipt)
        XCTAssertEqual(record.receivedUptime, 100)
        XCTAssertEqual(record.transmitterUptime, 5730698)
        XCTAssertEqual(record.sequence, 2664)
        XCTAssertEqual(record.glucoseRaw, 204)
        XCTAssertTrue(record.isReliable)
        XCTAssertTrue(buffer.clocks.isEmpty)
    }

    func testMalformedPacketsNeverBecomeUntimedEvidence() {
        var corrupt = glucosePacket; corrupt[10] ^= 1
        var wrongOpcode = Data(glucosePacket.dropLast(2)); wrongOpcode[0] = Opcode.transmitterTimeRx.rawValue
        for packet in [corrupt, Data(glucosePacket.prefix(8)), wrongOpcode.appendingCRC()] {
            var buffer = ResearchEvidenceBuffer()
            guard case .invalid = buffer.observeGlucose(packet, receivedAt: receipt, receivedUptime: 100, hasClock: false) else { return XCTFail("Invalid packet accepted") }
            XCTAssertTrue(buffer.untimed.isEmpty)
        }
    }

    func testUnknownStateDisplayOnlyAndOutOfRangeRemainUnreliableEvidence() {
        var unknown = Data(glucosePacket.dropLast(2)); unknown[12] = 255
        var display = Data(glucosePacket.dropLast(2)); display[11] |= 0x40
        var sentinel = Data(glucosePacket.dropLast(2)); sentinel[10] = 0xff; sentinel[11] = 0x0f
        var status = Data(glucosePacket.dropLast(2)); status[1] = 255
        for body in [unknown, display, sentinel, status] {
            var buffer = ResearchEvidenceBuffer()
            guard case .untimed = buffer.observeGlucose(body.appendingCRC(), receivedAt: receipt, receivedUptime: 100, hasClock: false) else { return XCTFail("Decoded quality evidence lost") }
            XCTAssertFalse(buffer.untimed[0].isReliable)
        }
    }

    func testRepeatedPacketRetainsDependenceAndSeparateReceiptEvidence() {
        var buffer = ResearchEvidenceBuffer()
        _ = buffer.observeGlucose(glucosePacket, receivedAt: receipt, receivedUptime: 100, hasClock: false)
        _ = buffer.observeGlucose(glucosePacket, receivedAt: receipt.addingTimeInterval(1), receivedUptime: 101, hasClock: false)
        let first = buffer.untimed[0], second = buffer.untimed[1]
        XCTAssertEqual(first.rawPacket, second.rawPacket)
        XCTAssertEqual(first.streamID, second.streamID)
        XCTAssertEqual(first.transmitterUptime, second.transmitterUptime)
        XCTAssertEqual(first.sequence, second.sequence)
        XCTAssertNotEqual(first.recordID, second.recordID)
        XCTAssertNotEqual(first.receivedAt, second.receivedAt)
    }

    func testLaterClockDoesNotMutateOrPromoteEarlierUntimedRecord() {
        var buffer = ResearchEvidenceBuffer()
        _ = buffer.observeGlucose(glucosePacket, receivedAt: receipt, receivedUptime: 100, hasClock: false)
        let original = buffer.untimed[0]
        XCTAssertNotNil(buffer.observeClock(clockPacket, receivedAt: receipt.addingTimeInterval(10), receivedUptime: 110))
        XCTAssertEqual(buffer.untimed.count, 1)
        XCTAssertEqual(buffer.untimed[0].recordID, original.recordID)
        XCTAssertEqual(buffer.untimed[0].receivedAt, original.receivedAt)
        XCTAssertEqual(buffer.clocks[0].streamID, original.streamID)
        XCTAssertEqual(buffer.clocks[0].rawPacket, clockPacket)
        XCTAssertEqual(buffer.clocks[0].receivedUptime, 110)
        XCTAssertEqual(buffer.clocks[0].transmitterUptime, 7471687)
    }

    func testBoundedBuffersExposeEveryDroppedRecord() {
        var buffer = ResearchEvidenceBuffer()
        for count in 0..<26 {
            _ = buffer.observeGlucose(glucosePacket, receivedAt: receipt, receivedUptime: Double(count), hasClock: false)
            _ = buffer.observeClock(clockPacket, receivedAt: receipt, receivedUptime: Double(count))
        }
        XCTAssertEqual(buffer.untimed.count, 24)
        XCTAssertEqual(buffer.clocks.count, 24)
        XCTAssertEqual(buffer.untimedOverflowCount, 2)
        XCTAssertEqual(buffer.clockOverflowCount, 2)
        XCTAssertEqual(buffer.untimed.first?.receivedUptime, 2)
    }

    func testInvalidClockIsNotRetainedAndClockedPacketsUseDistinctDisposition() {
        var buffer = ResearchEvidenceBuffer()
        var corrupt = clockPacket; corrupt[2] ^= 1
        XCTAssertNil(buffer.observeClock(corrupt, receivedAt: receipt, receivedUptime: 100))
        XCTAssertTrue(buffer.clocks.isEmpty)
        guard case .timed = buffer.observeGlucose(glucosePacket, receivedAt: receipt, receivedUptime: 100, hasClock: true) else { return XCTFail("Clocked decode must remain distinct") }
        XCTAssertTrue(buffer.untimed.isEmpty)
    }
}
#endif
