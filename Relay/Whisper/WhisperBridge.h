// Bridging header for the vendored whisper.cpp C API.
// (sherpa-onnx is imported as the SherpaOnnxC module — it ships its own
// modulemap in Vendor/sherpa, so it must not also be included here.)
#import "whisper.h"
