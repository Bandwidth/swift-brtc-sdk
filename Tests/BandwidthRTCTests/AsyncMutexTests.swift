import XCTest
@testable import BandwidthRTC

/// Tests for `AsyncMutex`, the lock backing `BandwidthRTCClient`'s publish-side serialization.
final class AsyncMutexTests: XCTestCase {

    func testWithLockSerializesConcurrentAccess() async {
        let mutex = AsyncMutex()
        let counter = Counter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    await mutex.withLock {
                        // A non-atomic read-increment-write: if withLock ever let two callers
                        // in at once, at least one increment would be lost.
                        let current = await counter.value
                        try? await Task.sleep(nanoseconds: 1_000_000)
                        await counter.set(current + 1)
                    }
                }
            }
        }

        let finalValue = await counter.value
        XCTAssertEqual(finalValue, 50)
    }

    func testWithLockReleasesEvenWhenBodyThrows() async {
        struct Boom: Error {}
        let mutex = AsyncMutex()

        do {
            try await mutex.withLock { throw Boom() }
            XCTFail("Expected Boom to propagate")
        } catch is Boom {
            // expected
        } catch {
            XCTFail("Unexpected error \(error)")
        }

        // A second acquisition must not hang - the failed body's defer should have unlocked.
        var ran = false
        await mutex.withLock { ran = true }
        XCTAssertTrue(ran)
    }

    func testHeavyContentionNeverLosesAWakeup() async {
        // Regression: lock() once checked isLocked and enqueued in separate critical sections,
        // so an unlock() between them stranded the waiter. A later lock user would wake it, so
        // each trial races only two callers: a stranded waiter then hangs and trips the timeout.
        let mutex = AsyncMutex()
        let done = expectation(description: "all critical sections finished")
        Task.detached {
            for _ in 0..<50_000 {
                async let first: Void = mutex.withLock {}
                async let second: Void = mutex.withLock {}
                _ = await (first, second)
            }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 30)
    }

    func testWaitersAreServedInOrder() async {
        let mutex = AsyncMutex()

        // Hold the lock until the stream yields, so every task below has to queue.
        var release: AsyncStream<Void>.Continuation!
        let releaseSignal = AsyncStream<Void> { release = $0 }
        let holder = Task {
            await mutex.withLock {
                for await _ in releaseSignal { break }
            }
        }
        try? await Task.sleep(nanoseconds: 5_000_000)

        let order = OrderTracker()
        var tasks: [Task<Void, Never>] = []
        for i in 0..<5 {
            tasks.append(Task {
                await mutex.withLock {
                    await order.append(i)
                }
            })
            // Give each task a chance to enqueue before starting the next, so arrival order is
            // deterministic.
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        release.yield()
        await holder.value
        for task in tasks { await task.value }

        let recorded = await order.values
        XCTAssertEqual(recorded, [0, 1, 2, 3, 4])
    }
}

private actor Counter {
    private(set) var value = 0
    func set(_ newValue: Int) { value = newValue }
}

private actor OrderTracker {
    private(set) var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
}
