Pod::Spec.new do |s|
  s.name         = "FlashcatRUM"
  s.module_name  = "DatadogRUM"
  s.version      = "0.3.0"
  s.summary      = "Flashcat iOS SDK - Real User Monitoring (RUM) module."

  s.homepage     = "https://github.com/flashcatcloud/fc-sdk-ios"
  s.social_media_url   = "mailto:support@flashcat.com"

  s.license            = { :type => "Apache", :file => 'LICENSE' }
  s.authors            = "developer@flashcat.com"

  s.swift_version = '5.9'
  s.ios.deployment_target = '12.0'
  s.tvos.deployment_target = '12.0'

  s.source = { :git => "https://github.com/flashcatcloud/fc-sdk-ios.git", :tag => s.version.to_s }

  s.source_files = ["DatadogRUM/Sources/**/*.swift"]

  s.resource_bundle = {
    "DatadogRUM" => "DatadogRUM/Resources/PrivacyInfo.xcprivacy"
  }

  s.dependency 'FlashcatInternal', s.version.to_s

end
