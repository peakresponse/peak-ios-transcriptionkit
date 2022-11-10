#
# Be sure to run `pod lib lint TranscriptionKit.podspec' to ensure this is a
# valid spec before submitting.
#
# Any lines starting with a # are optional, but their use is encouraged
# To learn more about a Podspec see https://guides.cocoapods.org/syntax/podspec.html
#

Pod::Spec.new do |s|
  s.name             = 'TranscriptionKit'
  s.version          = '0.1.0'
  s.summary          = 'A short description of TranscriptionKit.'
  s.description      = <<-DESC
TODO: Add long description of the pod here.
                       DESC

  s.homepage         = 'https://github.com/peakresponse/transcriptionkit'
  s.license          = { :type => 'LGPL', :file => 'LICENSE.md' }
  s.author           = { 'Francis Li' => 'francis@peakresponse.net' }
  s.source           = { :git => 'https://github.com/peakresponse/transcriptionkit.git', :tag => s.version.to_s }

  s.ios.deployment_target = '12.4'

  s.source_files = 'TranscriptionKit/Classes/**/*'
  
  # s.resource_bundles = {
  #   'TranscriptionKit' => ['TranscriptionKit/Assets/*.png']
  # }

  # s.public_header_files = 'Pod/Classes/**/*.h'
  s.frameworks = 'Accelerate', 'AVFoundation', 'Speech'
  # s.dependency 'AFNetworking', '~> 2.3'
  s.dependency 'AWSTranscribeStreaming', '~> 2.28.2'
end
