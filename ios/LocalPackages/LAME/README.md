# LAME for Tincall

LAME 3.100 C sources and platform configuration, taken from the `Sources/LAME` directory of [SwiftLAME 0.1.0](https://github.com/hidden-spectrum/SwiftLAME/tree/0.1.0/Sources/LAME). The original C sources and notices are preserved. The local Swift package manifest uses standard build settings and exports a dynamic library; Tincall calls the C API directly, without the SwiftLAME wrapper.

Used only for temporary MP3 model uploads: 16 kHz mono PCM16 input, 48 kbps output. Encoding runs outside MainActor. Retained audio, STT and playback keep their existing formats.

License: GNU LGPL 2.1, included in `LAME-LICENSE.txt`; source-file notices also apply. Keep this source, license and these build instructions with distributions. Tincall's license does not restrict the library rights granted by the LGPL, including modification, replacement, relinking and reverse engineering needed to debug those modifications.

## Rebuild and replace the iOS library

Use the matching Tincall release source on a Mac with Xcode. This directory includes the C source, headers, configuration and Swift package definition used by the app. The app calls LAME's public C API; a replacement must retain the symbols and ABI used by the app and support arm64 iOS.

1. Modify the library source in `ios/LocalPackages/LAME`. To rebuild it and relink the app, run from the release source root:

   ```sh
   bash tools/package-self-sign.sh /absolute/path/to/new-lame-rebuild
   ```

   This archives an unsigned arm64 iOS app using `Tincall` / `Release`. It builds the local LAME package as a dynamic framework and embeds it in `Tincall.app/Frameworks/LAME.framework`. `swift build` without an iOS destination builds for the Mac, not for an iPhone.

2. Prefer re-signing and installing the newly rebuilt IPA. To replace only the library in an existing **unencrypted, self-signing IPA**, unzip that IPA into a separate working directory and replace the entire `Payload/Tincall.app/Frameworks/LAME.framework` with the rebuilt framework at:

   ```text
   /absolute/path/to/new-lame-rebuild/Tincall.xcarchive/Products/Applications/Tincall.app/Frameworks/LAME.framework
   ```

3. The replacement invalidates signatures. Use your signing tool to re-sign the framework, extension and app, with matching profiles and App Group settings, before installing. Keep the app identifier and signing identity stable when updating an installation; back up important data first. An unsigned or modified App Store download is not an installable replacement.

4. Test a real raw-audio model upload, the path that uses MP3 encoding. STT and ordinary playback alone do not exercise LAME. Do not send private recordings to a provider just to test replacement.

The materials ZIP accompanying an official self-signing IPA includes this directory and notices. The matching full release source supplies the app code and build script needed for the rebuild. Rebuilding/replacing the LGPL library does not grant unrelated rights to redistribute Tincall or operate it for others. Modified library distributions must retain LGPL notices and corresponding modified source as applicable.

## 中文说明

这是 App 实际使用的 LAME 3.100 完整 C 源码、头文件、配置和动态库包定义。上面的步骤说明如何在对应版本的 Tincall 源码中修改库、为 arm64 iOS 重建并重新链接 App，或在未加密的自签 IPA 中替换整个 `LAME.framework` 后重新签名。仅运行不带 iOS 目标的 `swift build` 得到的是 Mac 版本。项目个人使用限制不覆盖 LGPL 授予的库修改、替换、重链接和必要调试权利；分发修改库时保留适用许可与对应源码。
