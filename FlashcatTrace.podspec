Pod::Spec.new do |s|
  s.name         = "FlashcatTrace"
  s.version      = "0.2.0"
  s.summary      = "Flashcat Trace Module."

  s.homepage     = "https://flashcat.cloud"

  s.license            = { :type => "Apache", :file => 'LICENSE' }
  s.authors            = { "Flashcat.Inc" => "support@flashcat.cloud" }

  s.swift_version = '5.9'
  s.ios.deployment_target = '12.0'
  s.tvos.deployment_target = '12.0'

  s.source = { :git => "https://github.com/flashcatcloud/fc-sdk-ios.git", :tag => "v#{s.version}" }

  s.source_files = ["FlashcatTrace/Sources/**/*.swift"]

  s.dependency 'FlashcatInternal', s.version.to_s
  s.dependency 'OpenTelemetrySwiftApi', '1.13.1'
end
