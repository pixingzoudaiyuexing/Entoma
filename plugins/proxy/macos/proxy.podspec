Pod::Spec.new do |s|
  s.name = 'proxy'
  s.version = '0.0.1'
  s.summary = 'Entoma system proxy integration'
  s.description = 'Scoped system proxy ownership and restoration.'
  s.homepage = 'https://github.com/pixingzoudaiyuexing/Entoma'
  s.license = { :file => '../LICENSE' }
  s.author = { 'Entoma' => 'https://github.com/pixingzoudaiyuexing/Entoma' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '13.0'
  s.swift_version = '5.0'
  s.frameworks = 'SystemConfiguration', 'Security', 'ServiceManagement'
end
