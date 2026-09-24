import CoreFoundation
import CryptoKit
import Foundation

/// Byte conversion stays in the native file adapter; editor and LSP buffers remain Unicode.
enum MacDocumentEncoding {
    static func decode(_ bytes: Data, encoding: DocumentEncoding?) throws -> DocumentReadDetails {
        let selected: DocumentEncoding
        if let encoding { selected = encoding }
        else if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { selected = .utf8Bom }
        else if String(data: bytes, encoding: .utf8) != nil { selected = .utf8 }
        else if let text = String(data: bytes, encoding: codec(.gb18030)) {
            // GB18030 is a superset of GBK. A four-byte sequence must keep its
            // original codec even if its decoded character is representable in GBK.
            selected = (try? encode(text, encoding: .gbk)) == bytes ? .gbk : .gb18030
        } else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        let payload = (selected == .utf8 || selected == .utf8Bom) && bytes.starts(with: [0xEF, 0xBB, 0xBF])
            ? Data(bytes.dropFirst(3)) : bytes
        guard let text = String(data: payload, encoding: codec(selected)) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return DocumentReadDetails(text: text, encoding: selected, identity: identity(bytes))
    }

    static func encode(_ text: String, encoding: DocumentEncoding) throws -> Data {
        guard var bytes = text.data(using: codec(encoding), allowLossyConversion: false),
              let decoded = String(data: bytes, encoding: codec(encoding)),
              Array(decoded.utf16) == Array(text.utf16) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        if encoding == .utf8Bom { bytes.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0) }
        return bytes
    }

    static func identity(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func codec(_ encoding: DocumentEncoding) -> String.Encoding {
        switch encoding {
        case .utf8, .utf8Bom: .utf8
        case .gbk: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GBK_95.rawValue)))
        case .gb18030: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case .shiftJIS: .shiftJIS
        case .windows1252: .windowsCP1252
        }
    }
}
