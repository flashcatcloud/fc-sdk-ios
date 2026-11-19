/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation
import DatadogInternal

public class DataStoreMock: DataStore {
    @ReadWriteLock
    public var storage: [String: DataStoreValueResult]

    /// When set, `value(forKey:callback:)` answers asynchronously on this queue and `flush()` waits for it,
    /// like the SDK's data store does. When `nil`, values are returned synchronously.
    public var queue: DispatchQueue?

    public init(storage: [String: DataStoreValueResult] = [:]) {
        self.storage = storage
    }

    public func setValue(_ value: Data, forKey key: String, version: DataStoreKeyVersion) {
        storage[key] = .value(value, version)
    }

    public func value(forKey key: String, callback: @escaping (DataStoreValueResult) -> Void) {
        guard let queue = queue else {
            callback(storage[key] ?? .noValue)
            return
        }
        queue.async { callback(self.storage[key] ?? .noValue) }
    }

    public func removeValue(forKey key: String) {
        storage[key] = nil
    }

    public func clearAllData() {
        storage.removeAll()
    }

    public func flush() {
        queue?.sync {}
    }

    // MARK: - Side Effects Observation

    public func value(forKey key: String) -> DataStoreValueResult? {
        return storage[key]
    }
}
