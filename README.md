# FoundationChat

A minimal macOS app and command-line tool for playing with Apple's on-device
[Foundation Models](https://developer.apple.com/documentation/foundationmodels)
(the Apple Intelligence model).

No Xcode project: a few Swift files built with `swiftc`.

- `Core.swift`: querying and model status, shared by both front ends
- `main.swift`: the app (SwiftUI in an `NSWindow`)
- `cli.swift`: the `isaac` command-line tool

## Requirements

- macOS 27 on Apple silicon
- Apple Intelligence enabled in System Settings
- Xcode 27 or its command-line tools (for `swiftc`)

## Build & run

```sh
./build.sh
open FoundationChat.app
```

`build.sh` builds both `FoundationChat.app` and the `isaac` command-line tool.

## Command line

```sh
./isaac "What is the capital of Australia?"   # answer and exit
echo "Summarize this: …" | ./isaac            # question from stdin
./isaac                                       # interactive prompt; Ctrl-D quits
./isaac --info                                # model variant and context size
```

Answers stream to stdout and errors go to stderr. Exit status: 0 on success,
1 if generation failed, 2 on bad usage, 3 if the model is unavailable.

To run it from anywhere, symlink it onto your `PATH`, e.g.
`ln -s "$PWD/isaac" ~/.local/bin/isaac`.

## Notes

- The model's context window depends on the model variant: 8,192 tokens for
  AFM 3 Core Advanced on macOS 27 (4,096 on macOS 26). The app's status line
  and `isaac --info` show what your Mac has.
- Each query is stateless: there's no conversation carry-over.
- Everything runs on-device; no network access at query time.
