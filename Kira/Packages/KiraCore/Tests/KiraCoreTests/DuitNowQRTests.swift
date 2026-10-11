import XCTest
@testable import KiraCore

final class DuitNowQRTests: XCTestCase {
    let parser = DuitNowQRParser()

    /// Public examples from PayNet's DuitNow QR developer documentation (Merchant-Presented Mode).
    let paynetRetailExample = "00020201021126410014A000000615000101065016640209123456789520499995303458540510.005802MY5909QRCSDNBHD6005BANGI6304343F"
    let paynetP2PExample = "00020201021126410014A000000615000101065016640209123456789520400005303458540510.005802MY5909AUSERNAME6005BANGI63043A23"

    func testCRCMatchesPublishedExamples() {
        XCTAssertEqual(CRC16CCITT.hex(String(paynetRetailExample.dropLast(4))), "343F")
        XCTAssertEqual(CRC16CCITT.hex(String(paynetP2PExample.dropLast(4))), "3A23")
        // Standard CRC-16/CCITT-FALSE check value.
        XCTAssertEqual(CRC16CCITT.hex("123456789"), "29B1")
    }

    func testParsesStaticRetailQR() throws {
        let payload = try parser.parse(paynetRetailExample)
        XCTAssertTrue(payload.isDuitNow)
        XCTAssertEqual(payload.initiation, .staticQR)
        XCTAssertEqual(payload.applicationIdentifier, "A0000006150001")
        XCTAssertEqual(payload.acquirerID, "501664")
        XCTAssertEqual(payload.qrID, "123456789")
        XCTAssertEqual(payload.merchantCategoryCode, "9999")
        XCTAssertEqual(payload.currency, .myr)
        XCTAssertEqual(payload.amount, TestData.rm("10.00"))
        XCTAssertEqual(payload.merchantName, "QRCSDNBHD")
        XCTAssertEqual(payload.merchantCity, "BANGI")
        XCTAssertTrue(payload.warnings.contains(.amountOnStaticQR))
        XCTAssertFalse(payload.isPersonToPerson)
    }

    func testP2PQRIsTransferNotExpense() throws {
        let payload = try parser.parse(paynetP2PExample)
        XCTAssertTrue(payload.isPersonToPerson)
        let draft = DuitNowDraftFactory.draft(from: payload)
        XCTAssertEqual(draft.kind, .transfer)
    }

    func testDynamicQRWithReferenceAndNoAmountStatic() throws {
        // SYNTHETIC dynamic QR built with the encoder.
        let merchantAccount = EMVTLV.encode([("00", "A0000006150001"), ("01", "890053"), ("02", "MERCH000123")])
        let additional = EMVTLV.encode([("01", "INV-7781"), ("05", "ORDER12345"), ("07", "T01")])
        let dynamic = EMVTLV.encodeWithCRC([("00", "01"), ("01", "12"), ("26", merchantAccount), ("52", "5812"), ("53", "458"),
                                           ("54", "23.40"), ("58", "MY"), ("59", "RESTORAN SYNTHETIC"), ("60", "SHAH ALAM"),
                                           ("61", "40000"), ("62", additional)])
        let payload = try parser.parse(dynamic)
        XCTAssertEqual(payload.initiation, .dynamicQR)
        XCTAssertEqual(payload.amount, TestData.rm("23.40"))
        XCTAssertEqual(payload.billNumber, "INV-7781")
        XCTAssertEqual(payload.referenceLabel, "ORDER12345")
        XCTAssertEqual(payload.terminalLabel, "T01")
        XCTAssertEqual(payload.postalCode, "40000")
        XCTAssertTrue(payload.warnings.isEmpty, "\(payload.warnings)")

        let staticNoAmount = EMVTLV.encodeWithCRC([("00", "01"), ("01", "11"), ("26", merchantAccount), ("52", "5814"), ("53", "458"),
                                                  ("58", "MY"), ("59", "MAMAK SYNTHETIC"), ("60", "KL")])
        let open = try parser.parse(staticNoAmount)
        XCTAssertNil(open.amount)
        XCTAssertTrue(open.requiresPayerAmount)
    }

    func testScannedQRIsAlwaysADraftAndNeverCounted() throws {
        let payload = try parser.parse(paynetRetailExample)
        let draft = DuitNowDraftFactory.draft(from: payload, scannedAt: TestData.date(2025, 10, 10))
        XCTAssertEqual(draft.status, .draft)
        XCTAssertEqual(draft.source, .duitNowQR)
        XCTAssertEqual(draft.channel, .duitNowQR)
        XCTAssertTrue(draft.flags.contains(.unconfirmedPayment))
        XCTAssertEqual(LedgerCalculator().summarize([draft]).netSpending, .zero())
    }

    func testDraftWithoutAmountIsFlagged() throws {
        let merchantAccount = EMVTLV.encode([("00", "A0000006150001"), ("01", "890053"), ("02", "X1")])
        let payload = try parser.parse(EMVTLV.encodeWithCRC([("00", "01"), ("01", "11"), ("26", merchantAccount), ("52", "5411"),
                                                             ("53", "458"), ("58", "MY"), ("59", "KEDAI RUNCIT"), ("60", "IPOH")]))
        let draft = DuitNowDraftFactory.draft(from: payload)
        XCTAssertTrue(draft.flags.contains(.amountMissing))
        XCTAssertEqual(draft.categoryID, BuiltInCategory.groceries.id)
    }

    func testRejectsCRCMismatch() {
        let tampered = paynetRetailExample.replacingOccurrences(of: "540510.00", with: "540599.00")
        XCTAssertThrowsError(try parser.parse(tampered)) { error in
            guard case DuitNowQRParser.ParseError.crcMismatch = error else { return XCTFail("\(error)") }
        }
    }

    func testRejectsMalformedPayloads() {
        XCTAssertThrowsError(try parser.parse("")) { XCTAssertEqual($0 as? DuitNowQRParser.ParseError, .empty) }
        XCTAssertThrowsError(try parser.parse("https://example.com/pay")) { XCTAssertEqual($0 as? DuitNowQRParser.ParseError, .notEMVQR) }
        XCTAssertThrowsError(try parser.parse("000201010211269")) { error in
            guard case DuitNowQRParser.ParseError.malformed = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try parser.parse(String(repeating: "0", count: 600))) { XCTAssertEqual($0 as? DuitNowQRParser.ParseError, .payloadTooLong) }
        // Missing CRC tag.
        XCTAssertThrowsError(try parser.parse("000201010211")) { XCTAssertEqual($0 as? DuitNowQRParser.ParseError, .crcMissing) }
    }

    func testRejectsMissingMandatoryFields() {
        let noName = EMVTLV.encodeWithCRC([("00", "01"), ("01", "11"), ("26", EMVTLV.encode([("00", "A0000006150001")])), ("52", "5411"), ("53", "458"), ("58", "MY")])
        XCTAssertThrowsError(try parser.parse(noName)) { XCTAssertEqual($0 as? DuitNowQRParser.ParseError, .missingMandatoryField("59 Merchant Name")) }
    }

    func testRejectsInvalidAmount() {
        let account = EMVTLV.encode([("00", "A0000006150001")])
        for bad in ["0.00", "1.2.3", "-5.00", "12.345"] {
            let qr = EMVTLV.encodeWithCRC([("00", "01"), ("01", "12"), ("26", account), ("52", "5411"), ("53", "458"), ("54", bad), ("58", "MY"), ("59", "X SHOP"), ("60", "KL")])
            XCTAssertThrowsError(try parser.parse(qr), bad)
        }
    }

    func testNonDuitNowEMVQRIsParsedWithWarning() throws {
        let other = EMVTLV.encodeWithCRC([("00", "01"), ("01", "11"), ("26", EMVTLV.encode([("00", "SG.PAYNOW"), ("01", "2")])), ("52", "0000"), ("53", "702"),
                                          ("58", "SG"), ("59", "SYNTH SG"), ("60", "SINGAPORE")])
        let payload = try parser.parse(other)
        XCTAssertFalse(payload.isDuitNow)
        XCTAssertTrue(payload.warnings.contains(.notDuitNow))
        XCTAssertTrue(payload.warnings.contains(.nonMalaysianCountry))
        XCTAssertEqual(payload.currency, .sgd)
    }

    func testSanitisesControlCharactersInMerchantName() throws {
        let account = EMVTLV.encode([("00", "A0000006150001")])
        let qr = EMVTLV.encodeWithCRC([("00", "01"), ("01", "11"), ("26", account), ("52", "5411"), ("53", "458"), ("58", "MY"),
                                       ("59", "EVIL\u{202E}SHOP\u{0007}"), ("60", "KL")])
        XCTAssertEqual(try parser.parse(qr).merchantName, "EVILSHOP")
    }

    func testTLVDuplicateTagsRejected() {
        XCTAssertThrowsError(try EMVTLV.parse("000201000201")) { XCTAssertEqual($0 as? TLVError, .duplicateID("00")) }
    }
}
