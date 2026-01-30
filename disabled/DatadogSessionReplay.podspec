Pod::Spec.new do |s|
  s.name         = "FlashcatSessionReplay"
  s.module_name  = "DatadogSessionReplay"
  s.version      = "0.4.0"
  s.summary      = "Official Datadog Session Replay SDK for iOS."

  s.homepage     = "https://www.datadoghq.com"
  s.social_media_url   = "https://twitter.com/datadoghq"

  s.license            = { :type => "Apache", :file => 'LICENSE' }
  s.authors            = {
    "Maciek Grzybowski" => "maciek.grzybowski@datadoghq.com",
    "Maciej Burda" => "maciej.burda@datadoghq.com",
    "Maxime Epain" => "maxime.epain@datadoghq.com",
    "Ganesh Jangir" => "ganesh.jangir@datadoghq.com"
  }

  s.swift_version = '5.9'
  s.ios.deployment_target = '12.0'
  s.tvos.deployment_target = '12.0'

  s.source = { :git => "https://github.com/flashcatcloud/fc-sdk-ios.git", :tag => s.version.to_s }

  s.source_files = ["DatadogSessionReplay/Sources/**/*.swift"]
  s.dependency 'FlashcatInternal', s.version.to_s
end
