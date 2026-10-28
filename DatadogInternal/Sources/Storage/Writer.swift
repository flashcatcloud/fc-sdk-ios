/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation

/// What became of a value given to a writer.
public enum WriteOutcome: Equatable {
    /// The value is written.
    case written
    /// The value can never be written, e.g. it cannot be encoded or it is too large.
    case failedPermanently
    /// The value could not be written now, e.g. as no file can be written to.
    case failedTransiently
}

/// A type, writing data.
public protocol Writer {
    /// Encodes given encodable value and metadata, and writes to the destination.
    /// - Parameters:
    ///   - value: Encodable value to write.
    ///   - metadata: Encodable metadata to write.
    ///   - completion: The block to execute after the write task is completed.
    func write<T: Encodable, M: Encodable>(value: T, metadata: M?, completion: @escaping CompletionHandler)

    /// Encodes given encodable value and metadata, writes to the destination, and reports whether it was written.
    /// - Parameters:
    ///   - value: Encodable value to write.
    ///   - metadata: Encodable metadata to write.
    ///   - onResult: Called after the write task is completed, with what became of the value.
    func write<T: Encodable, M: Encodable>(value: T, metadata: M?, onResult: @escaping (WriteOutcome) -> Void)
}

extension Writer {
    /// Default: a writer that cannot tell a failed write reports every write as written.
    public func write<T: Encodable, M: Encodable>(value: T, metadata: M?, onResult: @escaping (WriteOutcome) -> Void) {
        write(value: value, metadata: metadata, completion: { onResult(.written) })
    }

    /// Encodes given encodable value and writes to the destination.
    /// Uses `write(value:metadata:)` with `nil` metadata.
    ///
    /// - Parameter value: Encodable value to write.
    public func write<T: Encodable>(value: T) {
        write(value: value, completion: {})
    }

    /// Encodes given encodable value and writes to the destination.
    /// Uses `write(value:metadata:)` with `nil` metadata.
    ///
    /// - Parameters:
    ///   - value: Encodable value to write.
    ///   - completion: The block to execute after the write task is completed.
    public func write<T: Encodable>(value: T, completion: @escaping CompletionHandler) {
        let metadata: Data? = nil
        write(value: value, metadata: metadata, completion: completion)
    }

    /// Encodes given encodable value and metadata, and writes to the destination.
    /// - Parameters:
    ///   - value: Encodable value to write.
    ///   - metadata: Encodable metadata to write.
    public func write<T: Encodable, M: Encodable>(value: T, metadata: M?) {
        write(value: value, metadata: metadata, completion: {})
    }
}
