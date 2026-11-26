import Foundation

/// Just enough protobuf for Meshtastic's FromRadio / ToRadio: a field reader
/// and a canonical writer. Written from the wire-format spec; field numbers
/// come from meshtastic/protobufs `mesh.proto` and are checked by tests
/// against bytes produced by the official package (see Fixtures).
public enum Proto {
    public enum Value: Equatable {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(Data)
        case fixed32(UInt32)
    }

    public enum DecodeError: Error, Equatable {
        case truncated
        case unsupportedWireType(Int)
    }

    /// Every field in `data`, in order. Repeated fields appear several times.
    public static func fields(_ data: Data) throws -> [(Int, Value)] {
        var out: [(Int, Value)] = []
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            let key = try readVarint(bytes, &i)
            let field = Int(key >> 3)
            switch Int(key & 7) {
            case 0:
                out.append((field, .varint(try readVarint(bytes, &i))))
            case 1:
                guard i + 8 <= bytes.count else { throw DecodeError.truncated }
                var v: UInt64 = 0
                for k in 0..<8 { v |= UInt64(bytes[i + k]) << (8 * k) }
                i += 8
                out.append((field, .fixed64(v)))
            case 2:
                // Compare as UInt64 first: a huge length from a stranger's packet would trap in Int(...) or i + len.
                let raw = try readVarint(bytes, &i)
                guard raw <= UInt64(bytes.count - i) else { throw DecodeError.truncated }
                let len = Int(raw)
                out.append((field, .bytes(Data(bytes[i..<(i + len)]))))
                i += len
            case 5:
                guard i + 4 <= bytes.count else { throw DecodeError.truncated }
                var v: UInt32 = 0
                for k in 0..<4 { v |= UInt32(bytes[i + k]) << (8 * k) }
                i += 4
                out.append((field, .fixed32(v)))
            case let wt:
                throw DecodeError.unsupportedWireType(wt)
            }
        }
        return out
    }

    static func readVarint(_ b: [UInt8], _ i: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard i < b.count, shift < 64 else { throw DecodeError.truncated }
            let byte = b[i]
            i += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    /// Field lookup over a decoded message (last value wins, as in protobuf).
    public struct Message {
        public let fields: [(Int, Value)]

        public init(_ data: Data) throws { fields = try Proto.fields(data) }

        public func last(_ n: Int) -> Value? { fields.last { $0.0 == n }?.1 }

        public func uint32(_ n: Int) -> UInt32? {
            switch last(n) {
            case .varint(let v): return UInt32(truncatingIfNeeded: v)
            case .fixed32(let v): return v
            default: return nil
            }
        }

        public func int32(_ n: Int) -> Int32? {
            switch last(n) {
            case .varint(let v): return Int32(truncatingIfNeeded: v)
            case .fixed32(let v): return Int32(bitPattern: v)
            default: return nil
            }
        }

        public func uint64(_ n: Int) -> UInt64? {
            if case .varint(let v) = last(n) { return v }
            return nil
        }

        public func bool(_ n: Int) -> Bool? { uint64(n).map { $0 != 0 } }

        public func float(_ n: Int) -> Float? {
            if case .fixed32(let v) = last(n) { return Float(bitPattern: v) }
            return nil
        }

        public func bytes(_ n: Int) -> Data? {
            if case .bytes(let d) = last(n) { return d }
            return nil
        }

        public func string(_ n: Int) -> String? { bytes(n).map { String(decoding: $0, as: UTF8.self) } }

        public func message(_ n: Int) -> Message? { bytes(n).flatMap { try? Message($0) } }
    }

    /// Canonical proto3 writer: fields in the order written, defaults skipped
    /// by the callers (matching what the official encoders emit).
    public struct Writer {
        public internal(set) var data = Data()

        public init() {}

        mutating func key(_ field: Int, _ wireType: Int) { varint(UInt64(field << 3 | wireType)) }

        mutating func varint(_ v: UInt64) {
            var v = v
            while v > 0x7F {
                data.append(UInt8(v & 0x7F) | 0x80)
                v >>= 7
            }
            data.append(UInt8(v))
        }

        public mutating func uint(_ field: Int, _ v: UInt64) {
            key(field, 0)
            varint(v)
        }

        /// int32 fields: negative values are sign-extended to 10 bytes.
        public mutating func int32(_ field: Int, _ v: Int32) {
            key(field, 0)
            varint(UInt64(bitPattern: Int64(v)))
        }

        public mutating func bool(_ field: Int, _ v: Bool) { uint(field, v ? 1 : 0) }

        public mutating func fixed32(_ field: Int, _ v: UInt32) {
            key(field, 5)
            withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
        }

        public mutating func bytes(_ field: Int, _ d: Data) {
            key(field, 2)
            varint(UInt64(d.count))
            data.append(d)
        }

        public mutating func message(_ field: Int, _ build: (inout Writer) -> Void) {
            var inner = Writer()
            build(&inner)
            bytes(field, inner.data)
        }
    }
}
