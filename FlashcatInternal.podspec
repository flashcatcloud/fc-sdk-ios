Pod::Spec.new do |s|
  s.name         = "FlashcatInternal"
  s.version      = "0.2.0"
  s.summary      = "Flashcat Internal Package. This module is not for public use."

  s.homepage     = "https://flashcat.cloud"

  s.license            = { :type => "Apache", :file => 'LICENSE' }
  s.authors            = { "Flashcat.Inc" => "support@flashcat.cloud" }

  s.swift_version = '5.9'
  s.ios.deployment_target = '12.0'
  s.tvos.deployment_target = '12.0'
  s.watchos.deployment_target = '7.0'

  s.source = { :git => "https://github.com/flashcatcloud/fc-sdk-ios.git", :tag => s.version.to_s }

  s.source_files = ["FlashcatInternal/Sources/**/*.swift"]

end
