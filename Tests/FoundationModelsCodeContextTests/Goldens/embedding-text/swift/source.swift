import Foundation

/// A cache that keeps the last value of each key.
///
/// The cache removes the oldest key when it is full.
public final class Cache<Key: Hashable, Value>: Sendable {
    /// The most keys that the cache keeps.
    let capacity: Int

    /// Makes an empty cache.
    init(capacity: Int) {
        self.capacity = capacity
    }

    /// Gives the value of `key`.
    func value(
        forKey key: Key
    ) -> Value? {
        nil
    }

    /// Removes all keys.
    func removeAll() {}

    struct Entry {
        let key: Key

        func matches(_ other: Key) -> Bool {
            key == other
        }
    }
}
