Pod::Spec.new do |s|
  s.name         = "FlashcatInternal"
  s.module_name  = "DatadogInternal"
  s.version      = "0.5.0"
  s.summary      = "Flashcat iOS SDK - Internal utilities module (not for public use)."

  s.homepage     = "https://github.com/flashcatcloud/fc-sdk-ios"

  s.license            = { :type => "Apache", :file => 'LICENSE' }
  s.authors            = "developer@flashcat.com"

  s.swift_version = '5.9'
  s.ios.deployment_target = '12.0'
  s.tvos.deployment_target = '12.0'
  s.watchos.deployment_target = '7.0'

  s.source = { :git => "https://github.com/flashcatcloud/fc-sdk-ios.git", :tag => "v#{s.version}" }

  s.source_files = ["DatadogInternal/Sources/**/*.swift"]

end
