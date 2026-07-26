# FoundationChat

A minimal macOS app for playing with Apple's on-device [Foundation Models](https://developer.apple.com/documentation/foundationmodels)
(the ~3B-parameter Apple Intelligence model).

No Xcode project — one Swift file, built with `swiftc`.

## Requirements

- macOS 26 (Tahoe) on Apple silicon
- Apple Intelligence enabled in System Settings

## Build & run

```sh
./build.sh
open FoundationChat.app
```

## Notes

- The model's context window is 4,096 tokens. Each query is stateless — no
  conversation carry-over.
- Everything runs on-device; no network access at query time.
