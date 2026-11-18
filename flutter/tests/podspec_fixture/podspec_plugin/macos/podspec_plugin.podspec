Pod::Spec.new do |s|
  s.name             = 'podspec_plugin'
  s.version          = '1.0.0'
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.dependency 'Sparkle', '~> 2.6'
  s.platform         = :osx, '10.15'
end
