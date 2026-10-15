import Foundation

/// Learns which app you mean. Two signals, both decaying with a 30-day half-life:
///  - per query prefix: launching Blender after typing "ble" credits "b", "bl", "ble" -> Blender,
///    so next time "b" alone ranks Blender above Bartender;
///  - overall frecency: a small tie-breaker between equally good matches.
final class Usage {
    struct Rec: Codable { var s: Double; var t: Double } // decayed score, last update (unix time)

    private struct Store: Codable {
        var apps: [String: Rec] = [:]
        var queries: [String: [String: Rec]] = [:]
    }

    static let halfLife: Double = 30 * 86_400
    static let maxPrefix = 12

    private var store = Store()
    private let url: URL?
    private let saveQueue = DispatchQueue(label: "glasslight.usage", qos: .utility)

    init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let loaded = try? JSONDecoder().decode(Store.self, from: data) {
            store = loaded
        }
    }

    static func key(_ q: [UInt32]) -> String {
        var s = String.UnicodeScalarView()
        for v in q.prefix(maxPrefix) { if let u = Unicode.Scalar(v) { s.append(u) } }
        return String(s)
    }

    @inline(__always)
    private static func value(_ r: Rec?, _ now: Double) -> Double {
        guard let r else { return 0 }
        return r.s * pow(0.5, max(0, now - r.t) / halfLife)
    }

    /// Ranking bonus for `id` given the normalized query. Query history can lift an app across
    /// match tiers (it's what you meant last time); frecency only breaks near-ties.
    func boost(query: String, id: String, now: Double) -> Double {
        var b = 0.0
        let q = Self.value(store.queries[query]?[id], now)
        if q > 0 { b += min(320, 160 * log2(1 + q)) }
        let a = Self.value(store.apps[id], now)
        if a > 0 { b += min(100, 30 * log2(1 + a)) }
        return b
    }

    func record(query: [UInt32], id: String, now: Double = Date().timeIntervalSince1970) {
        store.apps[id] = Rec(s: Self.value(store.apps[id], now) + 1, t: now)
        for len in stride(from: 1, through: min(query.count, Self.maxPrefix), by: 1) {
            let prefix = Self.key(Array(query.prefix(len)))
            var bucket = store.queries[prefix] ?? [:]
            bucket[id] = Rec(s: Self.value(bucket[id], now) + 1, t: now)
            store.queries[prefix] = bucket
        }
        save(now: now)
    }

    private func save(now: Double) {
        guard let url else { return }
        // Forget anything that has decayed to almost nothing so the file stays tiny.
        store.apps = store.apps.filter { Self.value($0.value, now) > 0.05 }
        store.queries = store.queries.compactMapValues { bucket in
            let kept = bucket.filter { Self.value($0.value, now) > 0.05 }
            return kept.isEmpty ? nil : kept
        }
        let snapshot = store
        saveQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
