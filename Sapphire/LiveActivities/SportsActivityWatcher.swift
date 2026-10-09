import Foundation

@MainActor
final class SportsActivityWatcher {
    typealias Schedule = (TimeInterval, @escaping (Timer) -> Void) -> Timer

    private var timer: Timer?
    private let bootstrap: @MainActor () -> Void
    private let refresh: @MainActor () async -> Void
    private let onTick: @MainActor () async -> Void
    private let schedule: Schedule

    init(
        bootstrap: @escaping @MainActor () -> Void,
        refresh: @escaping @MainActor () async -> Void,
        onTick: @escaping @MainActor () async -> Void,
        schedule: @escaping Schedule = { interval, block in
            Timer.scheduledCoalescing(withTimeInterval: interval, repeats: true, block: block)
        }
    ) {
        self.bootstrap = bootstrap
        self.refresh = refresh
        self.onTick = onTick
        self.schedule = schedule
    }

    func update(enabled: Bool, isOnScreen: Bool) {
        #if SAPPHIRE_FULL_BUILD
        guard enabled else {
            stop()
            return
        }
        let interval: TimeInterval = isOnScreen ? 60.0 : 30.0
        if let timer, timer.isValid, abs(timer.timeInterval - interval) < 0.01 {
            return
        }
        stop()
        bootstrap()
        timer = schedule(interval) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.onTick()
            }
        }
        Task { await refresh() }
        #else
        stop()
        #endif
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }
}
