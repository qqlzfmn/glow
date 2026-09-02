import Foundation
import Combine

/// Polls sessions.json and publishes the current aggregate signal.
final class SessionPoller {
    struct State {
        let aggregateSignal: String
        let sessionCount: Int
        let sessions: [String: SessionEntry]
    }

    private let stateDir: String
    private let pollInterval: TimeInterval
    private var timer: Timer?
    private let subject: CurrentValueSubject<State, Never>

    var statePublisher: AnyPublisher<State, Never> {
        subject.eraseToAnyPublisher()
    }

    var currentState: State { subject.value }

    init(stateDir: String? = nil, pollIntervalMs: Int = 500) {
        self.stateDir = stateDir ?? StatePaths.stateDir
        self.pollInterval = TimeInterval(pollIntervalMs) / 1000.0
        self.subject = CurrentValueSubject<State, Never>(
            State(aggregateSignal: "idle", sessionCount: 0, sessions: [:])
        )
    }

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Force an immediate poll (e.g. right after manually clearing session state).
    func refresh() {
        poll()
    }

    private func poll() {
        let path = (stateDir as NSString).appendingPathComponent("sessions.json")
        guard let data = FileManager.default.contents(atPath: path) else {
            let empty = State(aggregateSignal: "idle", sessionCount: 0, sessions: [:])
            subject.send(empty)
            return
        }

        do {
            let decoder = JSONDecoder()
            let file = try decoder.decode(SessionFile.self, from: data)
            let now = Date().timeIntervalSince1970
            let ttl = 86400.0

            // Prune expired sessions.
            var sessions = file.sessions
            sessions = sessions.filter { _, entry in
                now - entry.updatedAt <= ttl
            }

            let aggregate = aggregateSignal(from: sessions)
            let state = State(
                aggregateSignal: aggregate,
                sessionCount: sessions.count,
                sessions: sessions
            )
            subject.send(state)
        } catch {
            // JSON parse failure — treat as empty, but trace it so silent data
            // loss is visible in logs.
            fputs("glow: corrupt sessions.json ignored (\(error.localizedDescription))\n", stderr)
            let empty = State(aggregateSignal: "idle", sessionCount: 0, sessions: [:])
            subject.send(empty)
        }
    }
}
