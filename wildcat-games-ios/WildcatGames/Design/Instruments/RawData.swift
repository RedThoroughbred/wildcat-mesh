import SwiftUI
import UIKit

// MARK: - Hex dump (pure logic)

/// Splits bytes into hex-dump lines. Works on a copy as `[UInt8]`, so Data
/// slices with non-zero start indices are safe.
enum HexDump {
    struct Line: Equatable {
        /// Offset of the first byte, e.g. 0x10.
        let offset: Int
        let bytes: [UInt8]
    }

    /// Lines of `perRow` bytes, stopping after `limit` bytes.
    static func lines(_ data: Data, perRow: Int = 16, limit: Int = 512) -> [Line] {
        let bytes = Array(data.prefix(max(0, limit)))
        let row = max(1, perRow)
        return stride(from: 0, to: bytes.count, by: row).map { start in
            Line(offset: start, bytes: Array(bytes[start..<min(start + row, bytes.count)]))
        }
    }

    /// Two lowercase hex digits.
    static func hex(_ byte: UInt8) -> String {
        let digits = Array("0123456789abcdef")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0f)]])
    }

    /// The offset column, at least two digits ("00", "10", "1f0").
    static func offset(_ value: Int, width: Int = 2) -> String {
        let s = String(max(0, value), radix: 16)
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }

    /// The whole payload as spaced hex, for the pasteboard.
    static func string(_ data: Data) -> String {
        data.map(hex).joined(separator: " ")
    }
}

// MARK: - Raw packet

/// A byte range to colour in a `RawPacketView` (the path, the header).
struct ByteHighlight {
    let range: Range<Int>
    var color: Color = Theme.meshcore
}

/// The raw packet drawer (AB `.hex`): a header ("RAW PACKET · GRP_TXT · 42 B"),
/// a hex dump with offsets and highlighted bytes, and a grid of decoded
/// fields underneath. The copy button puts the hex on the pasteboard.
struct RawPacketView: View {
    let data: Data
    var fields: [(label: String, value: String)] = []
    var title: String = "Raw packet"
    /// Mono detail after the title ("GRP_TXT · 42 B · 61 ms").
    var detail: String? = nil
    var highlights: [ByteHighlight] = []
    /// Bytes drawn in primary text (e.g. the header byte).
    var emphasis: Range<Int>? = nil

    @State private var copied = false

    init(data: Data, fields: [(label: String, value: String)] = [], title: String = "Raw packet",
         detail: String? = nil, highlights: [ByteHighlight] = [], emphasis: Range<Int>? = nil) {
        self.data = data
        self.fields = fields
        self.title = title
        self.detail = detail
        self.highlights = highlights
        self.emphasis = emphasis
    }

    private static let limit = 512

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ViewThatFits(in: .horizontal) {
                dump(perRow: 16)
                dump(perRow: 8)
                dump(perRow: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            if !fields.isEmpty {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                fieldGrid
            }
        }
        .background(Theme.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairlineStrong, lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(Theme.Fonts.label)
                .tracking(Theme.labelTracking)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize()
            if let detail {
                Text(detail)
                    .font(Theme.Fonts.raw)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                UIPasteboard.general.string = HexDump.string(data)
                Haptics.success()
                withAnimation(Theme.Motion.fade) { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    withAnimation(Theme.Motion.fade) { copied = false }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 13))
                    .foregroundStyle(copied ? Theme.ok : Theme.textTertiary)
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copied ? "Copied" : "Copy bytes")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
    }

    private func dump(perRow: Int) -> some View {
        let lines = HexDump.lines(data, perRow: perRow, limit: Self.limit)
        let width = data.count > 0x100 ? 3 : 2
        return VStack(alignment: .leading, spacing: 3) {
            if lines.isEmpty {
                Text("no bytes").foregroundStyle(Theme.textTertiary)
            }
            ForEach(lines, id: \.offset) { line in
                line.bytes.enumerated().reduce(
                    Text(HexDump.offset(line.offset, width: width) + " ").foregroundStyle(Theme.textQuaternary)
                ) { text, pair in
                    let index = line.offset + pair.offset
                    return text + Text(" " + HexDump.hex(pair.element)).foregroundStyle(color(at: index))
                }
            }
            if data.count > Self.limit {
                Text("… \(data.count - Self.limit) more bytes").foregroundStyle(Theme.textTertiary)
            }
        }
        .font(.system(size: 10.5, design: .monospaced))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .textSelection(.enabled)
        .accessibilityLabel("\(data.count) bytes")
    }

    private func color(at index: Int) -> Color {
        if let h = highlights.last(where: { $0.range.contains(index) }) { return h.color }
        if emphasis?.contains(index) == true { return Theme.textPrimary }
        return Theme.textSecondary
    }

    private var fieldGrid: some View {
        let rows = stride(from: 0, to: fields.count, by: 4).map { Array(fields[$0..<min($0 + 4, fields.count)]) }
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                if r > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                ReadoutRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { i, field in
                        if i > 0 { CellDivider() }
                        VStack(alignment: .leading, spacing: 2) {
                            CardLabel(field.label)
                            Text(field.value)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

// MARK: - Key/value grid

/// One row of a `KeyValueGrid`.
struct KeyValueItem: Identifiable {
    let id = UUID()
    let key: String
    let value: String
    /// Grey trailing note ("fw 1.8.2", "42 s").
    var note: String? = nil
    var tint: Color = Theme.textPrimary
}

/// Numbered raw rows (AB node detail "RAW"): "01  pubkey  c41977e2…  fw".
/// Long-press a row to copy its value or the whole row.
struct KeyValueGrid: View {
    let items: [KeyValueItem]
    var numbered: Bool = true
    var keyWidth: CGFloat = 64

    init(_ items: [KeyValueItem], numbered: Bool = true, keyWidth: CGFloat = 64) {
        self.items = items
        self.numbered = numbered
        self.keyWidth = keyWidth
    }

    /// Every row as "key: value" lines, for a "Copy all" action.
    static func text(_ items: [KeyValueItem]) -> String {
        items.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                if i > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    if numbered {
                        Text(String(format: "%02d", i + 1))
                            .foregroundStyle(Theme.textQuaternary)
                            .frame(width: 26, alignment: .leading)
                    }
                    Text(item.key)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .frame(width: keyWidth, alignment: .leading)
                    Text(item.value)
                        .foregroundStyle(item.tint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let note = item.note {
                        Text(note)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .padding(.leading, 8)
                    }
                }
                .font(.system(size: 11.5, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .contextMenu {
                    Button { copy(item.value) } label: { Label("Copy \(item.key)", systemImage: "doc.on.doc") }
                    Button { copy("\(item.key): \(item.value)") } label: { Label("Copy row", systemImage: "text.alignleft") }
                    Button { copy(Self.text(items)) } label: { Label("Copy all", systemImage: "list.bullet") }
                }
                .accessibilityElement(children: .combine)
                .accessibilityHint("Touch and hold to copy")
            }
        }
        .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        Haptics.success()
    }
}

// MARK: - Previews

#Preview("Raw data") {
    ScrollView {
        VStack(spacing: 16) {
            RawPacketView(data: Data([0x15, 0x00, 0x02, 0xa4, 0xc4, 0x3f, 0x9a, 0x07, 0xc1, 0xe2, 0x4d, 0x11, 0x8b, 0x70,
                                      0x2c, 0x5e, 0xd4, 0x0b, 0x93, 0x61, 0xaa, 0x7f, 0x03, 0xc8, 0x19, 0xe5, 0x42]),
                          fields: [("Path", "a4 › c4"), ("SNR", "4.5 dB"), ("RSSI", "−108"), ("RX", "Wildcat Bag")],
                          detail: "GRP_TXT · 27 B · 61 ms",
                          highlights: [ByteHighlight(range: 2..<5)], emphasis: 0..<1)
            KeyValueGrid([
                KeyValueItem(key: "pubkey", value: "c41977e25b0a93d1f00c", note: "copy"),
                KeyValueItem(key: "type", value: "REPEATER 0x02", note: "fw 1.8.2"),
                KeyValueItem(key: "radio", value: "910.525 · 62.5 · SF7 · 5", note: "22 dBm"),
            ])
        }
        .padding()
    }
    .screen()
}
