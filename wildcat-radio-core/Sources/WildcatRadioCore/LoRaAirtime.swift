import Foundation

/// LoRa time on air (Semtech SX127x/SX126x datasheet formula): explicit header, CRC on,
/// low data rate optimisation when a symbol lasts over 16 ms. Both firmwares use a
/// 16-symbol preamble. An estimate: good to a few percent.
public enum LoRaAirtime {
    /// Milliseconds for `bytes` on air. `codingRate` is the denominator (5-8 for 4/5-4/8).
    public static func milliseconds(bytes: Int, spreadingFactor sf: Int, bandwidthKHz bw: Double,
                                    codingRate cr: Int, preamble: Int = 16) -> Int? {
        guard bytes >= 0, (5...12).contains(sf), bw > 0, (5...8).contains(cr) else { return nil }
        let symbol = pow(2, Double(sf)) / (bw * 1000)
        let lowRate = symbol > 0.016 ? 1.0 : 0.0
        let n = Double(8 * bytes - 4 * sf + 28 + 16)
        let payloadSymbols = 8 + max((n / (4 * (Double(sf) - 2 * lowRate))).rounded(.up) * Double(cr), 0)
        return Int(((Double(preamble) + 4.25 + payloadSymbols) * symbol * 1000).rounded())
    }
}
