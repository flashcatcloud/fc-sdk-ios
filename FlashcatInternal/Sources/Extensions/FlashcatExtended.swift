/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation

/// Type that acts as a generic extension point for all `DatadogExtended` types.
public struct FlashcatExtension<ExtendedType> {
    /// Stores the type or meta-type of any extended type.
    public private(set) var type: ExtendedType

    /// Create an instance from the provided value.
    ///
    /// - Parameter type: Instance being extended.
    public init(_ type: ExtendedType) {
        self.type = type
    }
}

/// Protocol describing the `dd` extension points for Datadog extended types.
public protocol FlashcatExtended {
    /// Type being extended.
    associatedtype ExtendedType

    /// Static Datadog extension point.
    static var dd: FlashcatExtension<ExtendedType>.Type { get set }
    /// Instance Datadog extension point.
    var dd: FlashcatExtension<ExtendedType> { get set }
}

extension FlashcatExtended {
    /// Static Datadog extension point.
    public static var dd: FlashcatExtension<Self>.Type {
        get { FlashcatExtension<Self>.self }
        set {}
    }

    /// Instance Datadog extension point.
    public var dd: FlashcatExtension<Self> {
        get { FlashcatExtension(self) }
        set {}
    }
}

extension Array: FlashcatExtended {}
extension Dictionary: FlashcatExtended {}
