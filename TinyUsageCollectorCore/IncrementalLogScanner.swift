import Foundation
import CryptoKit
import TinyUsageDomain

public struct LogAggregate: Codable, Hashable, Sendable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var estimatedCost = Decimal.zero
    public var hasCost = false
    public var byDayAndModel: [String: LogBucket] = [:]
}

public struct LogBucket: Codable, Hashable, Sendable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var estimatedCost = Decimal.zero
    public var hasCost = false
}

public actor IncrementalJSONLScanner {
    public struct IndexEntry: Codable, Sendable {
        var size: UInt64
        var modificationDate: Date
        var offset: UInt64
        var parserVersion: Int
        var prefixLength: Int?
        var prefixDigest: String?
    }

    private let parserVersion: Int
    private let indexURL: URL?
    private var index: [String: IndexEntry] = [:]
    private var fileAggregates: [String: LogAggregate] = [:]

    private struct PersistedState: Codable { let index: [String: IndexEntry]; let aggregates: [String: LogAggregate] }

    public init(parserVersion: Int = 1, indexURL: URL? = nil) {
        self.parserVersion = parserVersion
        self.indexURL = indexURL
        if let indexURL, let data = try? Data(contentsOf: indexURL), let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
            index = state.index
            fileAggregates = state.aggregates
        }
    }

    public func scan(files: [URL]) -> LogAggregate {
        let activeKeys = Set(files.map { $0.standardizedFileURL.path })
        index = index.filter { activeKeys.contains($0.key) }
        fileAggregates = fileAggregates.filter { activeKeys.contains($0.key) }
        for file in files { scan(file: file) }
        persist()
        return fileAggregates.values.reduce(into: LogAggregate()) {
            $0.inputTokens += $1.inputTokens
            $0.outputTokens += $1.outputTokens
            $0.estimatedCost += $1.estimatedCost
            $0.hasCost = $0.hasCost || $1.hasCost
            for (key, bucket) in $1.byDayAndModel {
                var current = $0.byDayAndModel[key] ?? LogBucket()
                current.inputTokens += bucket.inputTokens
                current.outputTokens += bucket.outputTokens
                current.estimatedCost += bucket.estimatedCost
                current.hasCost = current.hasCost || bucket.hasCost
                $0.byDayAndModel[key] = current
            }
        }
    }

    private func persist() {
        guard let indexURL, let data = try? JSONEncoder().encode(PersistedState(index: index, aggregates: fileAggregates)) else { return }
        try? FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: indexURL, options: .atomic)
    }

    private func scan(file: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path), let byteCount = attributes[.size] as? NSNumber, let modified = attributes[.modificationDate] as? Date else { return }
        let size = byteCount.uint64Value
        let key = file.standardizedFileURL.path
        var entry = index[key] ?? IndexEntry(size: 0, modificationDate: .distantPast, offset: 0, parserVersion: parserVersion, prefixLength: nil, prefixDigest: nil)
        let prefixChanged = entry.offset > 0 && !Self.prefixMatches(file: file, entry: entry)
        if entry.parserVersion != parserVersion || size < entry.offset || prefixChanged {
            entry = IndexEntry(size: 0, modificationDate: .distantPast, offset: 0, parserVersion: parserVersion, prefixLength: nil, prefixDigest: nil)
            fileAggregates[key] = LogAggregate()
        }
        guard size != entry.size || modified != entry.modificationDate else { return }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: entry.offset)
            let data = try handle.readToEnd() ?? Data()
            let completeLength = data.lastIndex(of: 0x0A).map { data.distance(from: data.startIndex, to: $0) + 1 } ?? 0
            guard completeLength > 0 else { return }
            for line in data.prefix(completeLength).split(separator: 0x0A) where line.count <= 2 * 1024 * 1024 {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                var current = fileAggregates[key] ?? LogAggregate()
                let input = Self.int(object, keys: ["input_tokens", "inputTokens"])
                let output = Self.int(object, keys: ["output_tokens", "outputTokens"])
                let cost = Self.decimal(object, keys: ["cost_usd", "costUSD"])
                current.inputTokens += input
                current.outputTokens += output
                if let cost { current.estimatedCost += cost; current.hasCost = true }
                let date = Self.date(object, keys: ["timestamp", "created_at", "createdAt"]) ?? modified
                let model = Self.string(object, keys: ["model", "model_name", "modelName"]) ?? "unknown"
                let bucketKey = "\(Self.day(date))|\(model)"
                var bucket = current.byDayAndModel[bucketKey] ?? LogBucket()
                bucket.inputTokens += input
                bucket.outputTokens += output
                if let cost { bucket.estimatedCost += cost; bucket.hasCost = true }
                current.byDayAndModel[bucketKey] = bucket
                fileAggregates[key] = current
            }
            entry.offset += UInt64(completeLength)
            entry.size = size
            entry.modificationDate = modified
            entry.prefixLength = min(Int(entry.offset), 4096)
            entry.prefixDigest = Self.prefixDigest(file: file, length: entry.prefixLength ?? 0)
            index[key] = entry
        } catch { return }
    }

    private static func prefixMatches(file: URL, entry: IndexEntry) -> Bool {
        guard let length = entry.prefixLength, length > 0, let expected = entry.prefixDigest else {
            // Old indexes did not contain a fingerprint; rebuild once instead of trusting stale offsets.
            return false
        }
        return prefixDigest(file: file, length: length) == expected
    }

    private static func prefixDigest(file: URL, length: Int) -> String? {
        guard length > 0, let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: length), data.count == length else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func int(_ object: [String: Any], keys: [String]) -> Int {
        for key in keys { if let value = object[key] as? Int { return value } }
        for value in object.values { if let nested = value as? [String: Any] { let result = int(nested, keys: keys); if result != 0 { return result } } }
        return 0
    }

    private static func decimal(_ object: [String: Any], keys: [String]) -> Decimal? {
        for key in keys {
            if let value = object[key] as? NSNumber { return value.decimalValue }
            if let value = object[key] as? String { return Decimal(string: value) }
        }
        return nil
    }

    private static func string(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys { if let value = object[key] as? String { return value } }
        for value in object.values { if let nested = value as? [String: Any], let result = string(nested, keys: keys) { return result } }
        return nil
    }

    private static func date(_ object: [String: Any], keys: [String]) -> Date? {
        guard let value = string(object, keys: keys) else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

public struct LocalLogConnector: UsageSourceConnector {
    public let descriptor: UsageSourceDescriptor
    private let files: @Sendable () -> [URL]
    private let scanner: IncrementalJSONLScanner
    private let accountID: String

    public init(family: ProviderFamily, files: @escaping @Sendable () -> [URL], scanner: IncrementalJSONLScanner = .init()) {
        self.descriptor = UsageSourceDescriptor(id: "\(family.rawValue).local", family: family, displayName: "Local logs", provenance: .estimatedLocal)
        self.files = files
        self.scanner = scanner
        self.accountID = "\(family.rawValue)-local"
    }

    public func probe() async -> ProbeResult { files().isEmpty ? .init(.unsupported, message: "No local logs found.") : .init(.available) }

    public func fetch(context: FetchContext) async throws -> SourceSnapshot {
        let aggregate = await scanner.scan(files: files())
        let today = Self.day(context.now)
        let buckets = aggregate.byDayAndModel.filter { $0.key.hasPrefix(today + "|") }
        let input = buckets.values.reduce(0) { $0 + $1.inputTokens }
        let output = buckets.values.reduce(0) { $0 + $1.outputTokens }
        var cost = Decimal.zero
        var hasCost = false
        for (key, bucket) in buckets {
            if bucket.hasCost { cost += bucket.estimatedCost; hasCost = true }
            else {
                let model = String(key.dropFirst(today.count + 1))
                if let estimate = PublicPriceCatalog.estimate(family: descriptor.family, model: model, inputTokens: bucket.inputTokens, outputTokens: bucket.outputTokens) {
                    cost += estimate
                    hasCost = true
                }
            }
        }
        var metrics = [
            UsageMetric(id: "local.tokens.input.today", kind: .tokens, scope: .local, unit: .tokens, used: buckets.isEmpty ? nil : Decimal(input), provenance: .measuredLocal, collectedAt: context.now),
            UsageMetric(id: "local.tokens.output.today", kind: .tokens, scope: .local, unit: .tokens, used: buckets.isEmpty ? nil : Decimal(output), provenance: .measuredLocal, collectedAt: context.now),
            UsageMetric(id: "local.cost.today", kind: .cost, scope: .local, unit: .usd, used: hasCost ? cost : nil, provenance: .estimatedLocal, collectedAt: context.now)
        ]
        for (key, bucket) in buckets.sorted(by: { $0.key < $1.key }) {
            let model = String(key.dropFirst(today.count + 1))
            let stableModel = model.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { $0.append($1) }
            metrics.append(UsageMetric(id: "local.tokens.model.\(stableModel).today", kind: .tokens, scope: .local, unit: .tokens, used: Decimal(bucket.inputTokens + bucket.outputTokens), provenance: .measuredLocal, collectedAt: context.now))
        }
        return SourceSnapshot(source: descriptor, accountID: accountID, accountDisplayName: descriptor.family.displayName, metrics: metrics, fetchedAt: context.now, expiresAt: context.now.addingTimeInterval(10 * 60), warnings: [.init(id: "estimated-pricing", message: "Local cost uses public API list prices (catalog \(PublicPriceCatalog.version)); unknown models remain absent.")])
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

enum PublicPriceCatalog {
    static let version = "2026-09-18"

    static func estimate(family: ProviderFamily, model: String, inputTokens: Int, outputTokens: Int) -> Decimal? {
        let normalized = model.lowercased()
        let rates: (input: Decimal, output: Decimal)? = switch family {
        case .claude:
            if normalized.contains("opus") { (15, 75) }
            else if normalized.contains("haiku") { (Decimal(string: "0.8")!, 4) }
            else if normalized.contains("sonnet") { (3, 15) }
            else { nil }
        case .codex:
            if normalized.contains("gpt-5.4") { (Decimal(string: "2.5")!, 15) }
            else if normalized.contains("gpt-5.3-codex") { (Decimal(string: "1.75")!, 14) }
            else if normalized.contains("gpt-5") || normalized.contains("codex") { (Decimal(string: "1.25")!, 10) }
            else { nil }
        }
        guard let rates else { return nil }
        return (Decimal(inputTokens) * rates.input + Decimal(outputTokens) * rates.output) / 1_000_000
    }
}
