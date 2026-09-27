# webrpc SDK（Android / iOS）

| 平台 | 文件 | 架构 |
|------|------|------|
| Android | `libwebrpc-Android.so` | arm64-v8a |
| iOS | `libwebrpc-ios.a` | arm64（真机；模拟器需同平台库） |

Flutter 工程会把 Android `.so` 拷到 `android/app/src/main/jniLibs/arm64-v8a/libwebrpc.so`，
iOS 通过 `ios/Flutter/*.xcconfig` 强制链接静态库。
