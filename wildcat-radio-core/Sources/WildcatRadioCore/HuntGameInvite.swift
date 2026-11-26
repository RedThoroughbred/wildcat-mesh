import Foundation

extension HuntGame {
    /// Everything a hunter needs for one round of a game, in one QR code or link: the game
    /// (code, rounds, time limit, how a find counts, the hunt channel with its key), the
    /// round and who hides it, the host's node, and each piece's node, name, label-code check
    /// and, once hidden, its claim line and the spot the GPS guide uses (moved and rounded,
    /// see `ScentGuide.shared`; the real spot never leaves the hider's phone). Never sent over
    /// the mesh.
    ///
    ///     wildcat://huntgame/<base64url JSON>
    ///
    /// Short JSON keys keep the QR code small. Anything a hand-made or damaged link gets wrong
    /// makes `init(link:)` return nil; it never traps.
    public struct Invite: Equatable, Sendable, Codable, Identifiable {
        public static let prefix = "wildcat://huntgame/"
        public static let currentVersion = 1

        public struct Piece: Equatable, Sendable, Codable {
            public var i: Int
            public var node: UInt32
            public var name: String
            /// `HuntGame.codeCheck` of its label code.
            public var check: String
            public var claimRSSI: Double?
            public var claimSNR: Double?
            /// The guide's spot (already moved and rounded by the hider's phone).
            public var spot: Coordinate?

            public init(i: Int, node: UInt32, name: String, check: String, claimRSSI: Double? = nil, claimSNR: Double? = nil,
                        spot: Coordinate? = nil) {
                self.i = i; self.node = node; self.name = name; self.check = check
                self.claimRSSI = claimRSSI; self.claimSNR = claimSNR; self.spot = spot
            }

            private enum K: String, CodingKey { case i, n, a, c, r, q, s }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: K.self)
                i = try c.decode(Int.self, forKey: .i)
                node = try c.decode(UInt32.self, forKey: .n)
                name = try c.decode(String.self, forKey: .a)
                check = try c.decode(String.self, forKey: .c)
                claimRSSI = try c.decodeIfPresent(Double.self, forKey: .r)
                claimSNR = try c.decodeIfPresent(Double.self, forKey: .q)
                // [lat, lon] in 1e-5 degrees: whole numbers, so the link stays short.
                if let s = try c.decodeIfPresent([Int].self, forKey: .s) {
                    guard s.count == 2 else { throw DecodingError.dataCorruptedError(forKey: .s, in: c, debugDescription: "spot") }
                    spot = Coordinate(latitude: Double(s[0]) / 1e5, longitude: Double(s[1]) / 1e5)
                }
            }

            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: K.self)
                try c.encode(i, forKey: .i)
                try c.encode(node, forKey: .n)
                try c.encode(name, forKey: .a)
                try c.encode(check, forKey: .c)
                try c.encodeIfPresent(claimRSSI, forKey: .r)
                try c.encodeIfPresent(claimSNR, forKey: .q)
                if let spot, let lat = Self.e5(spot.latitude), let lon = Self.e5(spot.longitude) { try c.encode([lat, lon], forKey: .s) }
            }

            static func e5(_ v: Double) -> Int? {
                let x = (v * 1e5).rounded()
                return x.isFinite && abs(x) <= 18_000_000 ? Int(x) : nil
            }
        }

        public var version: Int
        /// The game's id (`HuntGame.id`).
        public var game: String
        public var code: String
        public var round: Int
        public var rounds: Int
        public var hider: String
        /// The hider's node, which referees the round.
        public var host: UInt32
        /// The hunt channel's ChannelSettings, raw (name and key).
        public var channel: Data
        /// Minutes per round; nil for no limit.
        public var limit: Int?
        /// `FoxReferee.Mode` raw value.
        public var mode: String
        /// When the round started (seconds since 1970, the hider's clock), once it has.
        public var started: TimeInterval?
        public var pieces: [Piece]

        public var id: String { "\(game)-\(round)" }

        private enum K: String, CodingKey { case v, g, c, r, n, h, o, k, l, m, s, p }

        public init(game: String, code: String, round: Int, rounds: Int, hider: String, host: UInt32, channel: Data,
                    limit: Int?, mode: FoxReferee.Mode, started: TimeInterval?, pieces: [Piece]) {
            version = Self.currentVersion
            self.game = game; self.code = code; self.round = round; self.rounds = rounds; self.hider = hider
            self.host = host; self.channel = channel; self.limit = limit; self.mode = mode.rawValue
            self.started = started; self.pieces = pieces
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            version = try c.decode(Int.self, forKey: .v)
            game = try c.decode(String.self, forKey: .g)
            code = try c.decode(String.self, forKey: .c)
            round = try c.decode(Int.self, forKey: .r)
            rounds = try c.decode(Int.self, forKey: .n)
            hider = try c.decode(String.self, forKey: .h)
            host = try c.decode(UInt32.self, forKey: .o)
            channel = try c.decode(Data.self, forKey: .k)
            limit = try c.decodeIfPresent(Int.self, forKey: .l)
            mode = try c.decode(String.self, forKey: .m)
            started = try c.decodeIfPresent(Double.self, forKey: .s)
            pieces = try c.decode([Piece].self, forKey: .p)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: K.self)
            try c.encode(version, forKey: .v)
            try c.encode(game, forKey: .g)
            try c.encode(code, forKey: .c)
            try c.encode(round, forKey: .r)
            try c.encode(rounds, forKey: .n)
            try c.encode(hider, forKey: .h)
            try c.encode(host, forKey: .o)
            try c.encode(channel, forKey: .k)
            try c.encodeIfPresent(limit, forKey: .l)
            try c.encode(mode, forKey: .m)
            try c.encodeIfPresent(started, forKey: .s)
            try c.encode(pieces, forKey: .p)
        }

        /// The link (and QR code) text.
        public var link: String {
            let e = JSONEncoder()
            e.outputFormatting = .sortedKeys
            let json = (try? e.encode(self)) ?? Data()
            return Self.prefix + json.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        /// Reads a link (nil when it isn't one, or doesn't make sense).
        public init?(link: String) {
            let s = link.trimmingCharacters(in: .whitespacesAndNewlines)
            guard s.lowercased().hasPrefix(Self.prefix), s.utf8.count <= 4096 else { return nil }
            var b64 = String(s.dropFirst(Self.prefix.count))
                .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b64.count % 4 != 0 { b64 += "=" }
            guard let data = Data(base64Encoded: b64), let v = try? JSONDecoder().decode(Invite.self, from: data), v.isSound else { return nil }
            self = v
        }

        /// Everything in range: a version this app reads, a game code, 1–3 rounds and pieces
        /// (numbered 1–3, each node once), names, checks, claim lines and spots that make sense.
        public var isSound: Bool {
            guard version == Self.currentVersion, !game.isEmpty, game.count <= 64, HuntGame.isValidCode(code),
                  (1...HuntGame.maxRounds).contains(rounds), (1...rounds).contains(round), hider.count <= 16,
                  !channel.isEmpty, channel.count <= 128, FoxReferee.Mode(rawValue: mode) != nil,
                  (1...HuntGame.maxPieces).contains(pieces.count) else { return false }
            if let limit, !(1...24 * 60).contains(limit) { return false }
            if let started, !(started.isFinite && started > 0) { return false }
            guard Set(pieces.map(\.i)).count == pieces.count, Set(pieces.map(\.node)).count == pieces.count else { return false }
            return pieces.allSatisfy { p in
                (1...HuntGame.maxPieces).contains(p.i) && !p.name.isEmpty && p.name.count <= 16
                    && p.check.count == 16 && p.check.allSatisfy(\.isHexDigit)
                    && (p.claimRSSI.map { $0.isFinite && HuntGame.claimRangeRSSI.contains($0) } ?? true)
                    && (p.claimSNR.map { $0.isFinite && HuntGame.claimRangeSNR.contains($0) } ?? true)
                    && (p.spot.map { abs($0.latitude) <= 90 && abs($0.longitude) <= 180 } ?? true)
            }
        }

        /// The time limit in seconds (nil: none).
        public var timeLimit: TimeInterval? { limit.map { TimeInterval($0) * 60 } }
        public var findMode: FoxReferee.Mode { FoxReferee.Mode(rawValue: mode) ?? .either }
        public var channelName: String { ChannelSettings(raw: channel).name }
        public var hostNode: NodeNum { NodeNum(host) }
        /// Every piece has its claim line and guide spot: the hider had hidden them all.
        public var isHidden: Bool { pieces.allSatisfy { $0.claimRSSI != nil } }
    }

    /// The invite for the round this phone hides (nil when it hunts this round). `host` is
    /// this phone's node; `channel` the hunt channel's raw settings, key included.
    public func invite(host: NodeNum, channel: Data) -> Invite? {
        guard let round = current, round.role == .hider else { return nil }
        let limit = settings.timeLimit.map { max(1, min(24 * 60, Int(($0 / 60).rounded()))) }
        return Invite(game: id, code: code, round: round.number, rounds: settings.rounds, hider: me, host: host.raw,
                      channel: channel, limit: limit, mode: settings.mode, started: round.startedAt,
                      pieces: pieces.map { p in
                          let h = round.hidden(p.index)
                          return Invite.Piece(i: p.index, node: p.node.raw, name: p.name, check: p.check,
                                              claimRSSI: h?.calibration.claimRSSI, claimSNR: h?.calibration.claimSNR,
                                              spot: h?.sharedSpot)
                      })
    }
}
