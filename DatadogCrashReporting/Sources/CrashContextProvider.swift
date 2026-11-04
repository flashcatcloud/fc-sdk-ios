/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation
import DatadogInternal

/// An interface for writing and reading  the `CrashContext`
internal protocol CrashContextProvider: AnyObject {
    /// Returns current `CrashContext` value.
    var currentCrashContext: CrashContext? { get }
    /// Notifies on `CrashContext` change.
    var onCrashContextChange: (CrashContext) -> Void { set get }
}

/// Manages the `CrashContext` reads and writes in a thread-safe manner.
internal class CrashContextCoreProvider: CrashContextProvider {
    /// Queue for synchronizing `unsafeCrashContext` updates.
    private let queue = DispatchQueue(
        label: "com.datadoghq.crash-context",
        target: .global(qos: .utility)
    )

    /// Unsafe callback instance.
    private var _callback: (CrashContext) -> Void = { _ in }

    /// Unsychronized `CrashContext`. The `queue` must be used to synchronize its mutation.
    private var _context: CrashContext? {
        didSet { _context.map(_callback) }
    }

    /// The RUM state in the last `CrashContext`, compared by identity to detect RUM changes, which
    /// `CrashContext` equality does not cover.
    private var rumContext: RUMFatalErrorContext?

    private var logAttributes: LogEventAttributes? {
        didSet { _context?.lastLogAttributes = logAttributes }
    }

    // MARK: - CrashContextProviderType

    var currentCrashContext: CrashContext? {
        queue.sync { _context }
    }

    var onCrashContextChange: (CrashContext) -> Void {
        get { queue.sync { self._callback } }
        set { queue.async { self._callback = newValue } }
    }
}

extension CrashContextCoreProvider: FeatureMessageReceiver {
    func receive(message: FeatureMessage, from core: DatadogCoreProtocol) -> Bool {
        switch message {
        case .context(let context):
            update(context: context)
        case let .payload(logAttributes as LogEventAttributes):
            queue.async { self.logAttributes = logAttributes }
        default:
            return false
        }

        return true
    }

    /// Updates crash context.
    ///
    /// - Parameter context: The updated core context.
    private func update(context: DatadogContext) {
        queue.async { [weak self] in
            guard let self = self else {
                return
            }

            let rumContext = context.additionalContext(ofType: RUMFatalErrorContext.self)
            let crashContext = CrashContext(context, lastLogAttributes: self.logAttributes)

            if crashContext != self._context || rumContext !== self.rumContext {
                self.rumContext = rumContext
                self._context = crashContext
            }
        }
    }
}

extension CrashContext {
    /// Creates the crash context from the core context, which carries the RUM state when RUM is enabled.
    init(_ context: DatadogContext, lastLogAttributes: LogEventAttributes?) {
        let rumContext = context.additionalContext(ofType: RUMFatalErrorContext.self)
        self.init(
            context,
            lastRUMViewEvent: rumContext?.view,
            lastRUMSessionState: rumContext?.sessionState,
            lastRUMAttributes: rumContext?.globalAttributes,
            lastLogAttributes: lastLogAttributes
        )
    }
}

extension CrashContextCoreProvider: Flushable {
    /// Awaits completion of all asynchronous operations.
    ///
    /// **blocks the caller thread**
    func flush() {
        queue.sync { }
    }
}
