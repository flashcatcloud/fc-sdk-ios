/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation

/// Sends one request straight away, outside the batched upload pipeline.
///
/// The batches are written to files and uploaded later, which is the right trade for events but
/// not for a signal that must leave the device while the app is still in use. The core implements
/// this with the HTTP client the uploads use, so the proxy configured at initialisation applies.
public protocol DirectRequestSender: AnyObject {
    /// Sends `request` and hands back how the server answered.
    ///
    /// The app is kept running in the background until the answer arrives, so a request made
    /// just before the user leaves the app still completes.
    func sendDirectly(request: URLRequest, completion: @escaping (Result<HTTPURLResponse, Error>) -> Void)
}
