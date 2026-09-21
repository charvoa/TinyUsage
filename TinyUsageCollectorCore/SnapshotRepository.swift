import Foundation

public actor FileSnapshotRepository: SnapshotRepository {
    private let directory: URL
    private var memory: [String: SourceSnapshot] = [:]

    public init(directory: URL) {
        self.directory = directory
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file), let snapshot = try? JSONDecoder().decode(SourceSnapshot.self, from: data) {
                    memory[snapshot.source.id] = snapshot
                }
            }
        }
    }

    public func lastGood(for sourceID: String) -> SourceSnapshot? { memory[sourceID] }

    public func commit(_ snapshot: SourceSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = snapshot.source.id.replacingOccurrences(of: "/", with: "-")
        try JSONEncoder().encode(snapshot).write(to: directory.appending(path: safeName + ".json"), options: .atomic)
        memory[snapshot.source.id] = snapshot
    }
}
