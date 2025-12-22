/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-Present Datadog, Inc.
 */

import Foundation
import FlashcatInternal

internal class MockFeature: DatadogRemoteFeature {
    static var name = "mock-feature"

    var messageReceiver: FeatureMessageReceiver = NOPFeatureMessageReceiver()
    var requestBuilder: FeatureRequestBuilder = MockRequestBuilder()
}

internal class MockRequestBuilder: FeatureRequestBuilder {
    func request(for events: [FlashcatInternal.Event], with context: FlashcatInternal.FlashcatContext, execution: FlashcatInternal.ExecutionContext) throws -> URLRequest {
        URLRequest.mockAny()
    }
}
