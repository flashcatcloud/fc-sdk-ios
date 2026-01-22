Pod::Spec.new do |s|
  s.name         = "FlashcatCrashReporting"
  s.version      = "0.2.0"
  s.summary      = "Official Flashcat Crash Reporting SDK for iOS."

  s.homepage     = "https://flashcat.cloud"

  s.license            = { :type => "Apache", :file => 'LICENSE' }
  s.authors            = { "Flashcat.Inc" => "support@flashcat.cloud" }

  s.swift_version = '5.9'
  s.ios.deployment_target = '12.0'
  s.tvos.deployment_target = '12.0'

  s.source = { :git => 'https://github.com/flashcatcloud/fc-sdk-ios.git', :tag => "v#{s.version}" }
  s.static_framework = true

  s.source_files = "FlashcatCrashReporting/Sources/**/*.swift"
  s.dependency 'FlashcatInternal', s.version.to_s
  s.dependency 'PLCrashReporter', '~> 1.12.0'

  s.resource_bundle = {
    "FlashcatCrashReporting" => "FlashcatCrashReporting/Resources/PrivacyInfo.xcprivacy"
  }
end
