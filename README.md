# FoundationChat

A minimal macOS app for playing with Apple's on-device [Foundation Models](https://developer.apple.com/documentation/foundationmodels)
(the ~3B-parameter Apple Intelligence model), with offline Wikipedia-backed fact checking.

No Xcode project — one Swift file, built with `swiftc`.

## Requirements

- macOS 26 (Tahoe) on Apple silicon
- Apple Intelligence enabled in System Settings

## Build & run

```sh
./build.sh
open FoundationChat.app
```

## Wikipedia fact checking

The model gets a `searchWikipedia` tool backed by a local SQLite FTS5 index of
Simple English Wikipedia. Results are ranked by BM25 (title-weighted) plus an
incoming-link-count boost computed at index time, so major articles beat obscure
ones that merely repeat the search terms. To build the index (one-time, ~5 min):

```sh
curl -L -o data/simplewiki-pages-articles.xml.bz2 \
  https://dumps.wikimedia.org/simplewiki/latest/simplewiki-latest-pages-articles.xml.bz2
bunzip2 -k data/simplewiki-pages-articles.xml.bz2
swiftc -O indexer.swift -o indexer
./indexer data/simplewiki-pages-articles.xml data/wiki.db
```

The app looks for `data/wiki.db` next to the `.app` bundle. Without it, the app
still works — queries just go to the bare model with no tools.

To use full English Wikipedia instead, point the same pipeline at
`enwiki-latest-pages-articles.xml.bz2` (~22 GB compressed; indexing takes hours).

## Notes

- The session keeps conversation context across prompts; "New Session" resets it.
- The model's context window is 4,096 tokens — if you hit a context-limit error,
  start a new session.
- Everything runs on-device; no network access at query time.
