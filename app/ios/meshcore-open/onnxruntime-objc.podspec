Pod::Spec.new do |s|
  s.name = 'onnxruntime-objc'
  s.version = '1.28.0'
  s.summary = 'Local ONNX Runtime Objective-C pod for MeshCore Open'
  s.homepage = 'https://github.com/microsoft/onnxruntime'
  s.license = { :type => 'MIT' }
  s.author = { 'ONNX Runtime' => 'onnxruntime@microsoft.com' }
  s.source = { :path => '.' }
  s.platform = :ios, '16.0'
  s.static_framework = true
  s.module_name = 'onnxruntime_objc'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'HEADER_SEARCH_PATHS' => '"${PODS_TARGET_SRCROOT}/objectivec" "${PODS_TARGET_SRCROOT}"',
    'OTHER_CPLUSPLUSFLAGS' => '-fvisibility=hidden -fvisibility-inlines-hidden',
  }
  s.source_files = 'objectivec/**/*.{h,mm}'
  s.exclude_files = [
    'objectivec/test/**',
    'objectivec/ort_training_session.mm',
    'objectivec/ort_training_session_internal.h',
    'objectivec/ort_checkpoint.mm',
    'objectivec/ort_checkpoint_internal.h',
    'objectivec/include/ort_training_session.h',
    'objectivec/include/ort_checkpoint.h',
    'objectivec/include/onnxruntime_training.h',
  ]
  s.public_header_files = 'objectivec/include/*.h'
  s.vendored_libraries = 'libonnxruntime-ios.a'
  s.compiler_flags = ['-std=c++17', '-fobjc-arc-exceptions', '-Wall', '-Wextra', '-Werror']
  s.requires_arc = true
end
