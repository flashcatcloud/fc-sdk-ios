Pod::Spec.new do |s|
  s.name         = "FlashcatCore"
  s.module_name  = "DatadogCore"
  s.version      = "3.3.0"
  s.summary      = "Flashcat iOS SDK - Core module for observability and monitoring."
  
  s.homepage     = "https://github.com/flashcatcloud/fc-sdk-ios"
  s.social_media_url   = "mailto:support@flashcat.com"

  s.license            = { :type => "Apache", :file => 'LICENSE' }
  s.authors            = "developer@flashcat.com"

  s.swift_version = '5.9'
  s.ios.deployment_target = '12.0'
  s.tvos.deployment_target = '12.0'
  s.watchos.deployment_target = '7.0'

  s.source = { :git => "https://github.com/flashcatcloud/fc-sdk-ios.git", :tag => s.version.to_s }
  
  s.source_files = ["DatadogCore/Sources/**/*.swift",
                    "DatadogCore/Private/**/*.{h,m}"]

  s.resource_bundle = {
    "DatadogCore" => "DatadogCore/Resources/PrivacyInfo.xcprivacy"
  }

  s.dependency 'FlashcatInternal', s.version.to_s

end
