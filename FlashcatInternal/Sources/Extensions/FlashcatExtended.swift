/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation

/// Type that acts as a generic extension point for all `FlashcatExtended` types.
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

/// Protocol describing the `dd` extension points for Flashcat extended types.
public protocol FlashcatExtended {
    /// Type being extended.
    associatedtype ExtendedType

    /// Static Flashcat extension point.
    static var dd: FlashcatExtension<ExtendedType>.Type { get set }
    /// Instance Flashcat extension point.
    var dd: FlashcatExtension<ExtendedType> { get set }
}

extension FlashcatExtended {
    /// Static Flashcat extension point.
    public static var dd: FlashcatExtension<Self>.Type {
        get { FlashcatExtension<Self>.self }
        set {}
    }

    /// Instance Flashcat extension point.
    public var dd: FlashcatExtension<Self> {
        get { FlashcatExtension(self) }
        set {}
    }
}

@available(*, deprecated, renamed: "FlashcatExtension")
public typealias DatadogExtension<ExtendedType> = FlashcatExtension<ExtendedType>

@available(*, deprecated, renamed: "FlashcatExtended")
public typealias DatadogExtended = FlashcatExtended

extension Array: FlashcatExtended {}
extension Dictionary: FlashcatExtended {}
