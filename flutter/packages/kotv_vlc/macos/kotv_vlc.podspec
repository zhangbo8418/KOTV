Pod::Spec.new do |s|
  s.name             = 'kotv_vlc'
  s.version          = '0.1.0'
  s.summary          = 'KOTV in-process libvlc Texture player'
  s.description      = 'Loads bundled libvlc and feeds frames into a Flutter Texture.'
  s.homepage         = 'https://github.com/bobo/KOTV'
  s.license          = { :type => 'MIT' }
  s.author           = { 'KOTV' => 'kotv@local' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.{c,h,m,mm}'
  s.public_header_files = 'Classes/KotvVlcPlugin.h'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES' => 'YES',
  }
  s.swift_version = '5.0'
  s.libraries = 'dl'
end
