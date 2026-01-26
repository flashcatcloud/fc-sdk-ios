Pod::Spec.new do |s|
  s.name         = "FlashcatTrace"
  s.module_name  = "DatadogTrace"
  s.version      = "0.3.0"
  s.summary      = "Flashcat iOS SDK - Distributed Tracing module."

  s.homepage     = "https://github.com/flashcatcloud/fc-sdk-ios"

  s.license            = { :type => "Apache", :file => 'LICENSE' }
  s.authors            = "developer@flashcat.com"

  s.swift_version = '5.9'
  s.ios.deployment_target = '12.0'
  s.tvos.deployment_target = '12.0'

  s.source = { :git => "https://github.com/flashcatcloud/fc-sdk-ios.git", :tag => s.version.to_s }

  s.source_files = ["DatadogTrace/Sources/**/*.swift"]

  s.dependency 'FlashcatInternal', s.version.to_s
  s.dependency 'OpenTelemetrySwiftApi', '1.13.1'
end
