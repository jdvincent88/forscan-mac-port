#if os(macOS)
FordLinkApp.main()
#else
print("FordLinkApp is a macOS SwiftUI app. Build it on a Mac: `swift run FordLinkApp` or `scripts/build-app.sh`.")
#endif
