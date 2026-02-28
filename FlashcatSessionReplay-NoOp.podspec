Pod::Spec.new do |s|
  s.name         = "FlashcatSessionReplay-NoOp"
  s.module_name  = "DatadogSessionReplay"
  s.version      = "0.4.0"
  s.summary      = "Flashcat iOS SDK - Session Replay module."

  s.homepage     = "https://github.com/flashcatcloud/fc-sdk-ios"

  s.license      = { :type => "Apache", :file => "LICENSE" }
  s.authors      = "developer@flashcat.com"

  s.swift_version = "5.9"
  s.ios.deployment_target = "12.0"
  s.tvos.deployment_target = "12.0"

  s.source = { :git => "https://github.com/flashcatcloud/fc-sdk-ios.git", :tag => "v#{s.version}" }

  s.source_files = ["DatadogSessionReplay/Sources/**/*.swift"]
  s.pod_target_xcconfig = {
    "OTHER_SWIFT_FLAGS" => "$(inherited) -D FC_NOOP_SESSION_REPLAY"
  }
  s.dependency "FlashcatInternal", s.version.to_s
end
