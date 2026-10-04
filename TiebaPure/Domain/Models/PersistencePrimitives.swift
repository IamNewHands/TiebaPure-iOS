import Foundation
import OSLog

enum PersistenceAvailability: Equatable, Sendable {
    case available
    case unavailable

    var canPersist: Bool {
        self == .available
    }
}

enum PersistenceFaultPoint: Equatable {
    case legacyMigration
    case repair
    case clearAll
}

struct PersistenceFaultInjector {
    static let none = PersistenceFaultInjector { _ in }

    private let handler: (PersistenceFaultPoint) throws -> Void

    init(_ handler: @escaping (PersistenceFaultPoint) throws -> Void) {
        self.handler = handler
    }

    func check(_ point: PersistenceFaultPoint) throws {
        try handler(point)
    }
}

struct PersistenceLoadResult<Value> {
    let value: Value
    let repairError: Error?
}

enum PersistenceDiagnostics {
    /// Category for the entries mirrored into 设置 → 诊断日志.
    static let logCategory = "本机存储"

    private static let logger = Logger(
        subsystem: "dev.infinityf4p.tiebapure",
        category: "Persistence"
    )

    /// Reports a store failure to OSLog *and* to the log the user can export.
    ///
    /// These failures used to reach OSLog only, which cannot be read from the
    /// phone: a store that never opened showed up as an unrelated draft error
    /// with a retry button that could never work, and no device could report
    /// why. Recording stays best-effort — it must never throw or block.
    static func report(_ error: Error, operation: String) {
        logger.error("\(operation, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        guard AppLog.isEnabled else { return }
        let message = "\(operation)：\(String(describing: error))"
        Task { await AppLog.shared.record(.error, Self.logCategory, message) }
    }
}

enum LegacyStorageMigration {
    enum DecodeError: Error {
        case invalidTopLevelArray
    }

    static func persistThenRemoveLegacyValue(
        defaults: UserDefaults,
        key: String,
        destinationIsDurable: Bool,
        persist: () throws -> Void
    ) throws {
        try persist()
        guard destinationIsDurable else { return }
        defaults.removeObject(forKey: key)
    }
}

struct FailableDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) {
        value = try? Value(from: decoder)
    }
}

enum PersistedArrayDecoder {
    static func decode<Element: Decodable>(_ type: Element.Type, from data: Data) -> [Element]? {
        guard let boxes = try? JSONDecoder().decode(
            [FailableDecodable<Element>].self,
            from: data
        ) else {
            return nil
        }
        return boxes.compactMap(\.value)
    }
}
