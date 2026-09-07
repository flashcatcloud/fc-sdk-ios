/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation

/// Defines a type responsible for sending HTTP requests.
internal protocol HTTPClient {
    /// Sends the provided request using HTTP.
    /// - Parameters:
    ///   - request: The request to be sent.
    ///   - delegate: The task-specific delegate.
    ///   - completion: A closure that receives a Result containing either an HTTPURLResponse or an Error.
    func send(request: URLRequest, delegate: URLSessionTaskDelegate?, completion: @escaping (Result<HTTPURLResponse, Error>) -> Void)

    /// Sends the provided request and hands back the response together with its body.
    ///
    /// Uploading only needs to know how the backend replied, so `send(request:)` discards the body.
    /// Asking the backend for something — the sampling configuration the console sets — needs what
    /// came back, and must go through the same client so it honours the proxy the customer
    /// configured rather than quietly bypassing it.
    /// - Parameters:
    ///   - request: The request to be sent.
    ///   - completion: A closure that receives a Result containing either the response and its body, or an Error.
    func fetch(request: URLRequest, completion: @escaping (Result<(response: HTTPURLResponse, body: Data), Error>) -> Void)
}

extension HTTPClient {
    /// Sends the provided request using HTTP.
    /// - Parameters:
    ///   - request: The request to be sent.
    ///   - completion: A closure that receives a Result containing either an HTTPURLResponse or an Error.
    func send(request: URLRequest, completion: @escaping (Result<HTTPURLResponse, Error>) -> Void) {
        self.send(request: request, delegate: nil, completion: completion)
    }
}
