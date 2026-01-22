Pod::Spec.new do |s|
  s.name         = "FlashcatCore"
  s.version      = "0.2.0"
  s.summary      = "Official Flashcat Swift SDK for iOS."
  
  s.homepage     = "https://flashcat.cloud"

  s.license            = { :type => "Apache", :file => 'LICENSE' }
  s.authors            = { "Flashcat.Inc" => "support@flashcat.cloud" }

  s.swift_version = '5.9'
  s.ios.deployment_target = '12.0'
  s.tvos.deployment_target = '12.0'
  s.watchos.deployment_target = '7.0'

  s.source = { :git => "https://github.com/flashcatcloud/fc-sdk-ios.git", :tag => "v#{s.version}" }
  
  s.source_files = ["FlashcatCore/Sources/**/*.swift",
                    "FlashcatCore/Private/**/*.{h,m}"]

  s.resource_bundle = {
    "FlashcatCore" => "FlashcatCore/Resources/PrivacyInfo.xcprivacy"
  }

  s.dependency 'FlashcatInternal', s.version.to_s

end
