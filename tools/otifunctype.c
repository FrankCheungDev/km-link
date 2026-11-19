// otifunctype.c — read the bridge functionType / identification bytes.
// Build:
//   SDK=$(xcrun --show-sdk-path)
//   (from the repository root; needs Sources/SCSITaskShim.c)
//   clang -target arm64-apple-macos13.0 -isysroot "$SDK" -framework IOKit -framework CoreFoundation -framework DiskArbitration -ISources -o /tmp/otifunctype Sources/SCSITaskShim.c tools/otifunctype.c

