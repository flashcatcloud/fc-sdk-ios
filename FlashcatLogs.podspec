Pod::Spec.new do |s|
  s.name         = "FlashcatLogs"
  s.module_name  = "DatadogLogs"
  s.version      = "0.4.0"
  s.summary      = "Flashcat iOS SDK - Logs module."

  s.homepage     = "https://github.com/flashcatcloud/fc-sdk-ios"

  s.license            = { :type => "Apache", :file => "LICENSE" }
  s.authors            = "developer@flashcat.com"

  s.swift_version = "5.9"
  s.ios.deployment_target = "12.0"
  s.tvos.deployment_target = "12.0"
  s.watchos.deployment_target = "7.0"

  s.source = { :git => "https://github.com/flashcatcloud/fc-sdk-ios.git", :tag => "v#{s.version}" }

  s.source_files = ["DatadogLogs/Sources/**/*.swift"]
  s.pod_target_xcconfig = {
    "OTHER_SWIFT_FLAGS" => "$(inherited) -D FC_NOOP_LOGS"
  }

  s.dependency "FlashcatInternal", s.version.to_s
end
