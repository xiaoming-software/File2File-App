# webrpc SDK（Android / iOS）

| 平台 | 文件 | 架构 |
|------|------|------|
| Android | `libwebrpc-Android.so` | arm64-v8a |
| iOS 真机 | `libwebrpc-ios.a` | arm64（iphoneos） |
| iOS 模拟器 | `libwebrpc-ios-simulator.a` | arm64（iphonesimulator） |

Flutter 工程会把 Android `.so` 拷到 `android/app/src/main/jniLibs/arm64-v8a/libwebrpc.so`，
iOS 通过 `ios/Flutter/*.xcconfig` 按 SDK 选择对应静态库。
