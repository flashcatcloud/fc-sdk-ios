Pod::Spec.new do |s|
  s.name         = "FlashcatTestUtilities"
  s.module_name  = "TestUtilities"
  s.version      = "3.3.0"
  s.summary      = "Flashcat iOS SDK - Testing Utilities (for internal testing only)."

  s.homepage     = "https://github.com/flashcatcloud/fc-sdk-ios"
  s.social_media_url   = "mailto:support@flashcat.com"

  s.license            = { :type => "Apache", :file => 'LICENSE' }
  s.authors            = "developer@flashcat.com"

  s.swift_version = '5.9'
  s.ios.deployment_target = '12.0'
  s.tvos.deployment_target = '12.0'

  s.source = { :git => "https://github.com/flashcatcloud/fc-sdk-ios.git", :tag => s.version.to_s }

  s.pod_target_xcconfig = {
    'ENABLE_TESTING_SEARCH_PATHS'=>'YES'
  }

  s.framework = 'XCTest'

  s.source_files = [
    "TestUtilities/Sources/**/*.swift"
  ]

  s.dependency 'FlashcatCore'
  s.dependency 'FlashcatInternal'
  s.dependency 'FlashcatRUM'
  s.dependency 'FlashcatTrace'
  s.dependency 'FlashcatCrashReporting'
  s.dependency 'FlashcatWebViewTracking'

end