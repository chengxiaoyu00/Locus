# idevice FFI

Locus uses the arm64 iPhone device library and matching C header from the MIT-licensed idevice v0.1.68 release, commit `d32c8189c51c2789496b0768039419c3705498c3`. [Upstream release](https://github.com/jkcoxson/idevice/releases/tag/v0.1.68) · [License](LICENSE.txt)

The release asset is `idevice-xcframework-v0.1.68.zip`. The files come from `swift/IDevice.xcframework/ios-arm64/`. The repository stores the device archive with lossless gzip compression. The Xcode build expands it locally before linking.

| File | SHA-256 |
| --- | --- |
| Upstream release ZIP | `c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7` |
| `libidevice_ffi.a` | `3dbb27b7f772a6d1d65ec509f05573c9337aa9f7621e8aa1db14f693329ca0cc` |
| `libidevice_ffi.a.gz` | `1ed9f32d189ec6b81901ac9be8633455da9018cba40a31c69a68ec09966654d7` |
| `idevice.h` | `696286794e8cf1c18a91d4dab5046cef4d9bae352f5e7a1ad33fbc0ba30d7ab4` |
