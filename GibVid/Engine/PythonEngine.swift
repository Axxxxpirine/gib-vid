import Foundation
import Synchronization

/// yt-dlp embarqué : un interpréteur Python qui tourne sur son propre thread.
final class PythonEngine: Sendable {
    static let shared = PythonEngine()

    struct Progress: Decodable, Sendable {
        let phase: String
        let fraction: Double?
    }

    struct Version: Decodable, Sendable {
        let version: String?
        let updated: Bool?
        let error: String?
    }

    struct DownloadResult: Decodable, Sendable {
        struct Item: Decodable, Sendable {
            let title: String
            let files: [String]
        }

        let ok: Bool
        let items: [Item]?
        let error: String?
        let cancelled: Bool?
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    private static let updateInterval: TimeInterval = 12 * 3600
    private static let lastUpdateKey = "lastEngineUpdateCheck"

    private let worker = WorkerThread(name: "Python", stackSize: 32 << 20)
    private let started = Mutex(false)
    private let progressHandler = Mutex<(@Sendable (Progress) -> Void)?>(nil)

    private init() {
        worker.start()
    }

    func onProgress(_ handler: @escaping @Sendable (Progress) -> Void) {
        progressHandler.withLock { $0 = handler }
    }

    /// Démarre Python, charge yt-dlp et le met à jour si la dernière vérification date.
    func prepare() async throws -> String? {
        var version: Version = try await call("configure", Paths.current)
        version = try await call("warmup", Empty())

        let lastCheck = UserDefaults.standard.double(forKey: Self.lastUpdateKey)
        if Date().timeIntervalSince1970 - lastCheck > Self.updateInterval {
            let result = try await update()
            if result.error == nil {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastUpdateKey)
            }
            version = result
        }
        return version.version
    }

    func update() async throws -> Version {
        let result: Version = try await call("update", Empty())
        if result.updated == true {
            _ = try await call("warmup", Empty()) as Version
        }
        return result
    }

    func download(url: String, into directory: URL) async throws -> DownloadResult {
        gib_set_cancelled(false)
        return try await call("download", DownloadRequest(url: url, outdir: directory.path))
    }

    func cancel() {
        gib_set_cancelled(true)
    }

    // MARK: - Appels vers Python

    private func call<Input: Encodable & Sendable, Output: Decodable & Sendable>(
        _ function: String, _ input: Input
    ) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            worker.enqueue {
                continuation.resume(with: Result {
                    try self.startIfNeeded()
                    let encoder = JSONEncoder()
                    encoder.keyEncodingStrategy = .convertToSnakeCase
                    let argument = String(decoding: try encoder.encode(input), as: UTF8.self)

                    guard let raw = gib_python_call(function, argument) else {
                        throw Failure(errorDescription: "Erreur interne de yt-dlp (\(function)).")
                    }
                    defer { free(raw) }
                    return try JSONDecoder().decode(Output.self, from: Data(String(cString: raw).utf8))
                })
            }
        }
    }

    /// Toujours appelé sur le thread Python.
    private func startIfNeeded() throws {
        guard !started.withLock({ $0 }) else { return }

        gib_set_callbacks({ script, ok in
            let result = JavaScriptRunner.run(String(cString: script))
            ok.pointee = result.ok
            return strdup(result.output)
        }, { json in
            PythonEngine.shared.forward(progress: String(cString: json))
        })

        let bundle = Bundle.main.bundleURL
        let pycache = Paths.caches.appending(path: "pycache")
        if let error = gib_python_start(
            bundle.appending(path: "python").path,
            bundle.appending(path: "app").path,
            pycache.path
        ) {
            defer { free(error) }
            throw Failure(errorDescription: "Python n’a pas pu démarrer : \(String(cString: error))")
        }
        started.withLock { $0 = true }
    }

    private func forward(progress json: String) {
        guard let event = try? JSONDecoder().decode(Progress.self, from: Data(json.utf8)) else { return }
        progressHandler.withLock { $0 }?(event)
    }
}

private struct Empty: Encodable, Sendable {}

private struct DownloadRequest: Encodable, Sendable {
    let url: String
    let outdir: String
}

private struct Paths: Encodable, Sendable {
    let support: String
    let caches: String
    let bundlePackages: String

    static var caches: URL { .cachesDirectory }

    static var current: Paths {
        let support = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return Paths(
            support: support.path,
            caches: caches.path,
            bundlePackages: Bundle.main.bundleURL.appending(path: "app_packages").path
        )
    }
}
