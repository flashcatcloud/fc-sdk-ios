Pod::Spec.new do |s|
  s.name         = "FlashcatSessionReplay"
  s.version      = "0.2.0"
  s.summary      = "Official Flashcat Session Replay SDK for iOS."

  s.homepage     = "https://flashcat.cloud"

  s.license            = { :type => "Apache", :file => 'LICENSE' }
  s.authors            = { "Flashcat.Inc" => "support@flashcat.cloud" }

  s.swift_version = '5.9'
  s.ios.deployment_target = '12.0'
  s.tvos.deployment_target = '12.0'

  s.source = { :git => "https://github.com/flashcatcloud/fc-sdk-ios.git", :tag => "v#{s.version}" }

  s.source_files = ["FlashcatSessionReplay/Sources/**/*.swift"]
  s.dependency 'FlashcatInternal', s.version.to_s
end
