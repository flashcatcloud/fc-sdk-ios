Pod::Spec.new do |s|
  s.name         = "FlashcatTestUtilities"
  s.module_name  = "TestUtilities"
  s.version      = "0.5.0"
  s.summary      = "Flashcat iOS SDK - Testing Utilities (for internal testing only)."

  s.homepage     = "https://github.com/flashcatcloud/fc-sdk-ios"

  s.license            = { :type => "Apache", :file => 'LICENSE' }
  s.authors            = "developer@flashcat.com"

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

  # Every module TestUtilities reaches into. It uses `@testable import` throughout, and a pod
  # target can only import what it declares — a module missing from this list does not degrade,
  # it fails the build of anything that pulls TestUtilities in through CocoaPods.
  s.dependency 'FlashcatCore'
  s.dependency 'FlashcatInternal'
  s.dependency 'FlashcatRUM'
  s.dependency 'FlashcatTrace'
  s.dependency 'FlashcatCrashReporting'
  s.dependency 'FlashcatWebViewTracking'
  s.dependency 'FlashcatLogs'
  s.dependency 'FlashcatSessionReplay'

end