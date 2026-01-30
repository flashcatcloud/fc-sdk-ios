Pod::Spec.new do |s|
  s.name         = "FlashcatCrashReporting"
  s.module_name  = "DatadogCrashReporting"
  s.version      = "0.3.0"
  s.summary      = "Flashcat iOS SDK - Crash Reporting module."

  s.homepage     = "https://github.com/flashcatcloud/fc-sdk-ios"

  s.license            = { :type => "Apache", :file => 'LICENSE' }
  s.authors            = "developer@flashcat.com"

  s.swift_version = '5.9'
  s.ios.deployment_target = '12.0'
  s.tvos.deployment_target = '12.0'

  s.source = { :git => 'https://github.com/flashcatcloud/fc-sdk-ios.git', :tag => "v#{s.version}" }
  s.static_framework = true

  s.source_files = "DatadogCrashReporting/Sources/**/*.swift"
  s.dependency 'FlashcatInternal', s.version.to_s
  s.dependency 'PLCrashReporter', '~> 1.12.0'

  s.resource_bundle = {
    "DatadogCrashReporting" => "DatadogCrashReporting/Resources/PrivacyInfo.xcprivacy"
  }
end
