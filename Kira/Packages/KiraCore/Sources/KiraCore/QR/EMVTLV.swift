import Foundation

/// CRC-16/CCITT-FALSE (ISO/IEC 13239, polynomial 0x1021, initial value 0xFFFF) as required by
/// EMV® QRCPS Merchant-Presented Mode and the PayNet DuitNow QR specification.
public enum CRC16CCITT {
    public static func checksum(_ bytes: some Sequence<UInt8>) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    public static func hex(_ string: String) -> String {
        String(format: "%04X", checksum(Array(string.utf8)))
    }
}

/// One EMV TLV data object: two-digit ID, two-digit length, value.
public struct TLVObject: Equatable, Sendable {
    public let id: String
    public let value: String
}

public enum TLVError: Error, Equatable {
    case truncated(at: Int)
    case invalidID(at: Int)
    case invalidLength(at: Int)
    case duplicateID(String)
}

/// Parser/encoder for EMV QR TLV strings. Lengths count characters; DuitNow payloads are ASCII,
/// but merchant names in tag 64 may be UTF-8, so we work on `Character`s.
public enum EMVTLV {
    public static func parse(_ payload: String, allowDuplicates: Bool = false) throws -> [TLVObject] {
        let characters = Array(payload)
        var objects: [TLVObject] = []
        var seen = Set<String>()
        var index = 0
        while index < characters.count {
            guard index + 4 <= characters.count else { throw TLVError.truncated(at: index) }
            let id = String(characters[index..<index + 2])
            guard id.allSatisfy(\.isASCII), id.allSatisfy(\.isNumber) else { throw TLVError.invalidID(at: index) }
            let lengthString = String(characters[index + 2..<index + 4])
            guard lengthString.allSatisfy(\.isASCII), lengthString.allSatisfy(\.isNumber), let length = Int(lengthString) else {
                throw TLVError.invalidLength(at: index + 2)
            }
            let start = index + 4
            guard start + length <= characters.count else { throw TLVError.truncated(at: start) }
            if !allowDuplicates {
                guard seen.insert(id).inserted else { throw TLVError.duplicateID(id) }
            }
            objects.append(TLVObject(id: id, value: String(characters[start..<start + length])))
            index = start + length
        }
        return objects
    }

    public static func encode(_ objects: [(String, String)]) -> String {
        objects.map { id, value in id + String(format: "%02d", value.count) + value }.joined()
    }

    /// Appends tag 63 with a freshly computed CRC.
    public static func encodeWithCRC(_ objects: [(String, String)]) -> String {
        let body = encode(objects) + "6304"
        return body + CRC16CCITT.hex(body)
    }
}
