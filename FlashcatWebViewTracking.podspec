Pod::Spec.new do |s|
  s.name         = "FlashcatWebViewTracking"
  s.module_name  = "DatadogWebViewTracking"
  s.version      = "0.5.0"
  s.summary      = "Flashcat iOS SDK - WebView Tracking module."

  s.homepage     = "https://github.com/flashcatcloud/fc-sdk-ios"

  s.license            = { :type => "Apache", :file => 'LICENSE' }
  s.authors            = "developer@flashcat.com"

  s.swift_version = '5.9'
  s.ios.deployment_target = '12.0'

  s.source = { :git => "https://github.com/flashcatcloud/fc-sdk-ios.git", :tag => "v#{s.version}" }

  s.source_files = ["DatadogWebViewTracking/Sources/**/*.swift"]

  s.dependency 'FlashcatInternal', s.version.to_s

end
