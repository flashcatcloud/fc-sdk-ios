Pod::Spec.new do |s|
  s.name         = "TestUtilities"
  s.version      = "0.2.0"
  s.summary      = "Flashcat Testing Utilities. This module is for internal testing and should not be published."

  s.homepage     = "https://flashcat.cloud"

  s.license            = { :type => "Apache", :file => 'LICENSE' }
  s.authors            = { "Flashcat.Inc" => "support@flashcat.cloud" }

  s.swift_version = '5.9'
  s.ios.deployment_target = '12.0'
  s.tvos.deployment_target = '12.0'

  s.source = { :git => "https://github.com/flashcatcloud/fc-sdk-ios.git", :tag => "v#{s.version}" }

  s.pod_target_xcconfig = {
    'ENABLE_TESTING_SEARCH_PATHS'=>'YES'
  }

  s.framework = 'XCTest'

  s.source_files = [
    "TestUtilities/Sources/**/*.swift"
  ]

  s.dependency 'FlashcatCore'
  s.dependency 'FlashcatInternal'
  s.dependency 'FlashcatLogs'
  s.dependency 'FlashcatRUM'
  s.dependency 'FlashcatSessionReplay'
  s.dependency 'FlashcatTrace'
  s.dependency 'FlashcatCrashReporting'
  s.dependency 'FlashcatWebViewTracking'

end