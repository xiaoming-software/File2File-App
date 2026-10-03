# Vendored `opus_flutter_ios`

Upstream `opus.xcframework` only ships **device arm64** and **simulator x86_64**.
Apple Silicon iOS Simulator needs **simulator arm64**, which caused:

`Error (Xcode): Framework 'opus' not found`

This copy adds a fat simulator slice (`arm64 + x86_64`) built from the same
libopus sources as `third_party/opus_flutter_android`.
