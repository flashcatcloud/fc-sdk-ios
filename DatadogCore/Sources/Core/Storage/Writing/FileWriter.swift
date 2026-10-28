/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation
import DatadogInternal

/// JSON encoder used to encode data.
private let jsonEncoder: JSONEncoder = .dd.default()

/// Writes data to files.
internal struct FileWriter: Writer {
    /// Orchestrator producing reference to writable file.
    let orchestrator: FilesOrchestratorType
    /// Algorithm to encrypt written data.
    let encryption: DataEncryption?
    /// Telemetry interface.
    let telemetry: Telemetry

    init(
        orchestrator: FilesOrchestratorType,
        encryption: DataEncryption?,
        telemetry: Telemetry
    ) {
        self.orchestrator = orchestrator
        self.encryption = encryption
        self.telemetry = telemetry
    }

    // MARK: - Writing data

    /// Encodes given encodable value and metadata, and writes it to the file.
    /// If encryption is available, the data is encrypted before writing.
    /// - Parameters:
    ///  - value: Encodable value to write.
    ///  - metadata: Encodable metadata to write.
    func write<T: Encodable, M: Encodable>(value: T, metadata: M?, completion: @escaping CompletionHandler) {
        _ = persist(value: value, metadata: metadata)
        completion()
    }

    func write<T: Encodable, M: Encodable>(value: T, metadata: M?, onResult: @escaping (WriteOutcome) -> Void) {
        onResult(persist(value: value, metadata: metadata))
    }

    /// Encodes and appends the value and its metadata to the writable file.
    /// - Returns: what became of the value: a value that cannot be encoded (including one too large) never will be,
    ///   while one the app's encryption fails for, or a file that cannot be written to now, may be later.
    private func persist<T: Encodable, M: Encodable>(value: T, metadata: M?) -> WriteOutcome {
        var encoded: Data = .init()
        if let metadata = metadata {
            do {
                let encodedMetadata = try encode(value: metadata, blockType: .eventMetadata)
                encoded.append(encodedMetadata)
            } catch {
                DD.logger.error("(\(orchestrator.trackName)) Failed to encode metadata", error: error)
                telemetry.error("(\(orchestrator.trackName)) Failed to encode metadata", error: error)
            }
        }

        do {
            let encodedValue = try encode(value: value, blockType: .event)
            encoded.append(encodedValue)
        } catch {
            let cause = (error as? EncryptionFailure)?.cause ?? error
            DD.logger.error("(\(orchestrator.trackName)) Failed to encode value", error: cause)
            telemetry.error("(\(orchestrator.trackName)) Failed to encode value", error: cause)
            return error is EncryptionFailure ? .failedTransiently : .failedPermanently
        }

        // Make sure both event and event metadata are written to the same file.
        // This is to avoid a situation where event is written to one file and event metadata to another.
        // If this happens, the reader will not be able to match event with its metadata.
        let writeSize = UInt64(encoded.count)
        let file: WritableFile
        do {
            file = try orchestrator.getWritableFile(writeSize: writeSize)
        } catch {
            DD.logger.error("(\(orchestrator.trackName)) Failed to get writable file for \(writeSize) bytes", error: error)
            telemetry.error("(\(orchestrator.trackName)) Failed to get writable file for \(writeSize) bytes", error: error)
            return .failedTransiently
        }

        do {
            try file.append(data: encoded)
#if DD_BENCHMARK
            bench.meter.counter(metric: "ios.benchmark.bytes_written")
                .increment(by: encoded.count, attributes: ["track": orchestrator.trackName])
#endif
        } catch {
            DD.logger.error("(\(orchestrator.trackName)) Failed to write \(writeSize) bytes to file", error: error)
            telemetry.error("(\(orchestrator.trackName)) Failed to write \(writeSize) bytes to file", error: error)
            return .failedTransiently
        }
        return .written
    }

    /// Encodes the given encodable value and encrypt it if encryption is available.
    ///
    /// The returned data format:
    ///
    ///     +- 2 bytes -+-  4 bytes -+- n bytes  -|
    ///     |    0x00   | block size | block data |
    ///     +-----------+------------+------------+
    ///
    /// Where the 2 first bytes represents the `block type` of
    /// an event.
    ///
    /// - Parameter event: The value to encode.
    /// - Returns: Data representation of the value.
    private func encode<T: Encodable>(value: T, blockType: BatchBlockType) throws -> Data {
        let data = try jsonEncoder.encode(value)
        return try BatchDataBlock(
            type: blockType,
            data: encrypt(data: data)
        ).serialize(
            maxLength: orchestrator.performance.maxObjectSize
        )
    }

    /// Encrypts data if encryption is available.
    ///
    /// If no encryption, the data is returned.
    ///
    /// - Parameter data: The data to encrypt.
    /// - Returns: Encrypted data.
    private func encrypt(data: Data) throws -> Data {
        guard let encryption = encryption else {
            return data
        }

        do {
            return try encryption.encrypt(data: data)
        } catch {
            throw EncryptionFailure(cause: error)
        }
    }

    /// The app's encryption failed: unlike encoding, it may succeed later.
    private struct EncryptionFailure: Error {
        let cause: Error
    }
}
