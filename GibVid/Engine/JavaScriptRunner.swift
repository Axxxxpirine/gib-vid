import JavaScriptCore

/// Exécute les scripts du solveur yt-dlp-ejs et renvoie ce qu'ils écrivent avec `console.log`.
enum JavaScriptRunner {
    static func run(_ script: String) -> (ok: Bool, output: String) {
        guard let context = JSContext() else { return (false, "JSContext indisponible") }

        var lines: [String] = []
        var failure: String?
        let log: @convention(block) (String) -> Void = { lines.append($0) }
        context.setObject(log, forKeyedSubscript: "__gibLog" as NSString)
        context.exceptionHandler = { _, exception in
            failure = exception?.toString() ?? "exception JavaScript"
        }
        context.evaluateScript("""
            globalThis.console = {
                log: (...args) => __gibLog(args.map(String).join(' ')),
                info() {}, warn() {}, error() {}, debug() {},
            };
            """)
        context.evaluateScript(script)

        if let failure { return (false, failure) }
        return (true, lines.joined(separator: "\n"))
    }
}
