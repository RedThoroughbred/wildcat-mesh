import CryptoKit
import Foundation
import WildcatRadioCore

/// Geo Gifts: a message locked to a place. The message is sealed with a key
/// derived from the grid cell of the exact spot; a phone can only derive it
/// (and open the gift) while its GPS is in or next to that cell. Recipients
/// get a teaser and a hint area, never the spot itself.
///
/// It's a friendly lock for a game, not a vault: someone determined could
/// try every cell in the hint area. Good enough to keep the surprise.
struct Gift: Equatable, Identifiable {
    enum Precision: UInt8, CaseIterable, Identifiable {
        case tight = 0, easy = 1, loose = 2
        var id: UInt8 { rawValue }
        /// Grid cell size in metres.
        var metres: Double { [30, 100, 300][Int(rawValue)] }
        var title: String { ["Tight (about 30 m)", "Easy (about 100 m)", "Loose (about 300 m)"][Int(rawValue)] }
    }

    var id: UInt32
    var precision: Precision
    /// Where to look: centre and radius (metres). Radius 0 means the centre is the exact spot.
    var hintCenter: LatLon
    var hintRadius: Int
    var created: Date
    var teaser: String
    /// nonce + ciphertext + tag.
    var sealed: Data
}

enum GiftCodec {
    static let magic: [UInt8] = [0x57, 0x47, 0x47]   // "WGG"
    static let typeGift: UInt8 = 1
    static let typeOpened: UInt8 = 2
    static let maxMessageBytes = 140
    static let maxTeaserBytes = 40

    // MARK: Lock

    struct Cell: Hashable { let band: Int; let lat: Int32; let lon: Int32 }

    static func cell(_ p: LatLon, _ precision: Gift.Precision, band: Int? = nil) -> Cell {
        let b = band ?? Int(floor(p.lat))
        let latStep = precision.metres / 111_320
        let lonStep = precision.metres / (111_320 * cos((Double(b) + 0.5) * .pi / 180))
        return Cell(band: b, lat: Int32(floor(p.lat / latStep)), lon: Int32(floor(p.lon / lonStep)))
    }

    static func key(id: UInt32, precision: Gift.Precision, cell: Cell) -> SymmetricKey {
        var d = Data("WGG1".utf8)
        withUnsafeBytes(of: id.littleEndian) { d.append(contentsOf: $0) }
        d.append(precision.rawValue)
        withUnsafeBytes(of: Int32(cell.band).littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: cell.lat.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: cell.lon.littleEndian) { d.append(contentsOf: $0) }
        return SymmetricKey(data: SHA256.hash(data: d))
    }

    static func seal(_ message: String, at spot: LatLon, id: UInt32, precision: Gift.Precision) throws -> Data {
        let box = try AES.GCM.seal(Data(message.utf8), using: key(id: id, precision: precision, cell: cell(spot, precision)))
        return box.combined!
    }

    /// Tries the cells around `here` (and the neighbouring latitude bands).
    static func open(_ gift: Gift, at here: LatLon) -> String? {
        guard let box = try? AES.GCM.SealedBox(combined: gift.sealed) else { return nil }
        let base = Int(floor(here.lat))
        for band in [base, base - 1, base + 1] {
            let c = cell(here, gift.precision, band: band)
            for dy in -1...1 {
                for dx in -1...1 {
                    let k = key(id: gift.id, precision: gift.precision,
                                cell: Cell(band: band, lat: c.lat + Int32(dy), lon: c.lon + Int32(dx)))
                    if let plain = try? AES.GCM.open(box, using: k) { return String(decoding: plain, as: UTF8.self) }
                }
            }
        }
        return nil
    }

    // MARK: Wire format (fits one LoRa packet)
    // "WGG" 1 | id u32 | precision u8 | hint lat i32 (1e-5) | hint lon i32 | hint radius u16 | created u32 |
    // teaser len u8 + utf8 | sealed (nonce 12 + ciphertext + tag 16)

    /// Bytes on air: 24 header bytes, the teaser, and the sealed message (12-byte nonce + 16-byte tag).
    static func encodedSize(message: String, teaser: String) -> Int {
        52 + min(teaser.utf8.count, maxTeaserBytes) + message.utf8.count
    }

    static func encode(_ g: Gift) -> Data {
        var d = Data(magic + [typeGift])
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        put(g.id)
        d.append(g.precision.rawValue)
        put(Int32((g.hintCenter.lat * 1e5).rounded()))
        put(Int32((g.hintCenter.lon * 1e5).rounded()))
        put(UInt16(clamping: g.hintRadius))
        put(UInt32(max(0, g.created.timeIntervalSince1970)))
        let teaser = Array(g.teaser.utf8Prefix(maxTeaserBytes).utf8)
        d.append(UInt8(teaser.count))
        d.append(contentsOf: teaser)
        d.append(g.sealed)
        return d
    }

    static func decode(_ d: Data) -> Gift? {
        let b = [UInt8](d)
        guard b.count > 26, Array(b[0..<3]) == magic, b[3] == typeGift else { return nil }
        var i = 4
        func take<T: FixedWidthInteger>(_: T.Type) -> T {
            var v: T = 0
            for k in 0..<MemoryLayout<T>.size { v |= T(truncatingIfNeeded: UInt64(b[i + k]) << (8 * k)) }
            i += MemoryLayout<T>.size
            return v
        }
        let id = take(UInt32.self)
        guard let precision = Gift.Precision(rawValue: b[i]) else { return nil }
        i += 1
        let lat = Double(take(Int32.self)) / 1e5
        let lon = Double(take(Int32.self)) / 1e5
        let radius = Int(take(UInt16.self))
        let created = Date(timeIntervalSince1970: TimeInterval(take(UInt32.self)))
        guard i < b.count else { return nil }
        let tlen = Int(b[i]); i += 1
        guard i + tlen + 28 <= b.count else { return nil }
        let teaser = String(decoding: b[i..<(i + tlen)], as: UTF8.self)
        i += tlen
        return Gift(id: id, precision: precision, hintCenter: LatLon(lat: lat, lon: lon), hintRadius: radius,
                    created: created, teaser: teaser, sealed: Data(b[i...]))
    }

    static func openedReceipt(id: UInt32) -> Data {
        var d = Data(magic + [typeOpened])
        withUnsafeBytes(of: id.littleEndian) { d.append(contentsOf: $0) }
        return d
    }

    static func receiptID(_ d: Data) -> UInt32? {
        let b = [UInt8](d)
        guard b.count == 8, Array(b[0..<3]) == magic, b[3] == typeOpened else { return nil }
        return UInt32(b[4]) | UInt32(b[5]) << 8 | UInt32(b[6]) << 16 | UInt32(b[7]) << 24
    }

    // MARK: Links (no radio needed)

    static let linkPrefix = "wildcat://gift/"

    static func link(_ g: Gift) -> String {
        linkPrefix + encode(g).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func gift(fromLink s: String) -> Gift? {
        guard let r = s.range(of: linkPrefix) else { return nil }
        var b64 = String(s[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        return Data(base64Encoded: b64).flatMap(decode)
    }

    /// A hint area around `spot`: `radius` metres, its centre moved randomly
    /// inside it so the spot isn't simply the middle.
    static func hint(for spot: LatLon, radius: Int) -> LatLon {
        guard radius > 0 else { return spot }
        return Geo.offset(spot, distance: Double.random(in: 0...(Double(radius) * 0.6)), bearing: Double.random(in: 0..<360))
    }
}
