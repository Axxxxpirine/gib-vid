import Observation
import UIKit

@Observable
@MainActor
final class DownloadModel {
    enum Phase: Equatable {
        case idle
        case analyzing
        case downloading(Double)
        case saving
        case done(count: Int)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .analyzing, .downloading, .saving: true
            default: false
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var clipboardHasLink = false
    private(set) var engineVersion: String?
    private(set) var engineNote: String?

    private let engine = PythonEngine.shared
    private var preparation: Task<Void, Never>?

    init() {
        engine.onProgress { [weak self] event in
            Task { @MainActor in self?.apply(event) }
        }
    }

    // MARK: - Actions

    func launch() {
        guard preparation == nil else { return }
        preparation = Task {
            do {
                engineVersion = try await engine.prepare()
            } catch {
                engineNote = error.localizedDescription
            }
        }
    }

    func tapBigButton() {
        guard !phase.isBusy else { return }
        guard let link = Self.linkFromClipboard() else {
            phase = .failed("Aucun lien dans le presse-papiers.")
            return
        }
        start(link)
    }

    /// gibvid://  → télécharge le lien du presse-papiers (pratique avec Raccourcis / Toucher le dos).
    /// gibvid://?url=…  → télécharge ce lien.
    func handle(url: URL) {
        guard url.scheme == "gibvid", !phase.isBusy else { return }
        let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "url" }?.value
            .flatMap(URL.init(string:))
        if let target { start(target) } else { tapBigButton() }
    }

    func cancel() {
        engine.cancel()
    }

    func updateEngine() {
        guard !phase.isBusy, engineNote != "Mise à jour…" else { return }
        engineNote = "Mise à jour…"
        Task {
            await preparation?.value
            do {
                let result = try await engine.update()
                engineVersion = result.version ?? engineVersion
                engineNote = result.error != nil ? "Mise à jour impossible"
                    : result.updated == true ? "Mis à jour" : "Déjà à jour"
            } catch {
                engineNote = "Mise à jour impossible"
            }
            try? await Task.sleep(for: .seconds(3))
            engineNote = nil
        }
    }

    func refreshClipboard() async {
        let pasteboard = UIPasteboard.general
        if pasteboard.hasURLs {
            clipboardHasLink = true
            return
        }
        let patterns = try? await pasteboard.detectedPatterns(for: [\.probableWebURL])
        clipboardHasLink = patterns?.contains(\.probableWebURL) ?? false
    }

    // MARK: - Téléchargement

    private func start(_ link: URL) {
        phase = .analyzing
        Task { await run(link) }
    }

    private func run(_ link: URL) async {
        let background = UIApplication.shared.beginBackgroundTask(withName: "download")
        defer { UIApplication.shared.endBackgroundTask(background) }

        guard await PhotoLibrary.requestAccess() else {
            phase = .failed("Autorise Gib Vid à ajouter des vidéos dans Réglages › Photos.")
            return
        }

        let directory = URL.temporaryDirectory.appending(path: "jobs/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let result = try await engine.download(url: link.absoluteString, into: directory)
            if result.cancelled == true {
                phase = .idle
                return
            }
            guard result.ok, let items = result.items else {
                Self.journal("✗ affiché : \(result.error ?? "-")")
                phase = .failed(result.error ?? "Téléchargement impossible.")
                return
            }

            phase = .saving
            for (index, item) in items.enumerated() {
                let files = item.files.map { URL(filePath: $0) }
                let video = try await VideoAssembler.photosReady(
                    from: files, output: directory.appending(path: "photos-\(index).mp4"))
                try await PhotoLibrary.saveVideo(at: video)
            }
            phase = .done(count: items.count)
            try? await Task.sleep(for: .seconds(4))
            if case .done = phase { phase = .idle }
        } catch {
            Self.journal("✗ Swift : \(error)")
            phase = .failed(error.localizedDescription)
        }
    }

    /// Même journal que le côté Python (Caches/gibvid.log).
    private static func journal(_ message: String) {
        let line = Data("\(Date.now.formatted(.iso8601)) \(message)\n".utf8)
        let url = URL.cachesDirectory.appending(path: "gibvid.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }

    private func apply(_ event: PythonEngine.Progress) {
        guard phase.isBusy, phase != .saving else { return }
        switch event.phase {
        case "analyzing": phase = .analyzing
        case "downloading": phase = .downloading(event.fraction ?? 0)
        default: break
        }
    }

    private static func linkFromClipboard() -> URL? {
        let pasteboard = UIPasteboard.general
        if let text = pasteboard.string {
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            let matches = detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
            if let url = matches.lazy.compactMap(\.url).first(where: { $0.scheme?.hasPrefix("http") == true }) {
                return url
            }
        }
        if let url = pasteboard.url, url.scheme?.hasPrefix("http") == true {
            return url
        }
        return nil
    }
}
