Pod::Spec.new do |s|
  s.name             = 'podspec_plugin'
  s.version          = '1.0.0'
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.dependency 'GoogleMaps', '~> 8.4'
  s.platform         = :ios, '13.0'
end
