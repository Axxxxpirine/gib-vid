import Foundation

/// Thread unique qui exécute ses tâches dans l'ordre.
///
/// Python et le solveur JavaScript de YouTube sont très récursifs : on leur donne
/// une pile bien plus grande que celle des threads GCD (512 Ko).
final class WorkerThread: Thread, @unchecked Sendable {
    private let condition = NSCondition()
    private var jobs: [@Sendable () -> Void] = []

    init(name: String, stackSize: Int) {
        super.init()
        self.name = name
        self.stackSize = stackSize
        self.qualityOfService = .userInitiated
    }

    func enqueue(_ job: @escaping @Sendable () -> Void) {
        condition.lock()
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }

    override func main() {
        while true {
            condition.lock()
            while jobs.isEmpty { condition.wait() }
            let job = jobs.removeFirst()
            condition.unlock()
            job()
        }
    }
}
