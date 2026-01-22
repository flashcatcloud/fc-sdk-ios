Pod::Spec.new do |s|
  s.name         = "FlashcatRUM"
  s.version      = "0.2.0"
  s.summary      = "Flashcat Real User Monitoring Module."

  s.homepage     = "https://flashcat.cloud"

  s.license            = { :type => "Apache", :file => 'LICENSE' }
  s.authors            = { "Flashcat.Inc" => "support@flashcat.cloud" }

  s.swift_version = '5.9'
  s.ios.deployment_target = '12.0'
  s.tvos.deployment_target = '12.0'

  s.source = { :git => "https://github.com/flashcatcloud/fc-sdk-ios.git", :tag => s.version.to_s }

  s.source_files = ["FlashcatRUM/Sources/**/*.swift"]

  s.resource_bundle = {
    "FlashcatRUM" => "FlashcatRUM/Resources/PrivacyInfo.xcprivacy"
  }

  s.dependency 'FlashcatInternal', s.version.to_s

end
