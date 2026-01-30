/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 * Modified by Flashcat, Inc.
 */

import Foundation

/// Flashcat Site configuration for data uploads.
public enum FlashcatSite: String {
    /// China based servers (default).
    /// Sends data to [browser.flashcat.cloud](https://browser.flashcat.cloud/).
    case cn
    /// Staging environment.
    /// Sends data to [jira.flashcat.cloud](https://jira.flashcat.cloud/).
    case staging
}

extension FlashcatSite {
    public var endpoint: URL {
        switch self {
        // swiftlint:disable force_unwrapping
        case .cn: return URL(string: "https://browser.flashcat.cloud/")!
        case .staging: return URL(string: "https://jira.flashcat.cloud/")!
        // swiftlint:enable force_unwrapping
        }
    }
}
