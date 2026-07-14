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

Tick the **"Fact-check with Wikipedia"** checkbox to answer a query with
retrieval-augmented generation against a local SQLite FTS5 index of Simple
English Wikipedia. Left unchecked (the default), queries go straight to the
bare model.

When enabled, each query runs a three-step flow:

1. **Keyword extraction** — the model turns the question into topical search
   terms (a `@Generable` struct), dropping framing words like "farthest" or
   "most" that would otherwise pollute the search.
2. **Retrieval** — the index is searched with progressive term relaxation
   (all terms, then drop the least important, etc.), ranked by title-weighted
   BM25 plus an incoming-link-count boost computed at index time so major
   articles beat obscure ones that merely repeat the terms.
3. **Grounded answer** — the model answers from the retrieved extracts only,
   and the article titles used are shown as sources.

To build the index (one-time, ~5 min):

```sh
curl -L -o data/simplewiki-pages-articles.xml.bz2 \
  https://dumps.wikimedia.org/simplewiki/latest/simplewiki-latest-pages-articles.xml.bz2
bunzip2 -k data/simplewiki-pages-articles.xml.bz2
swiftc -O indexer.swift -o indexer
./indexer data/simplewiki-pages-articles.xml data/wiki.db
```

The app looks for `data/wiki.db` next to the `.app` bundle. Without it, the
fact-check checkbox is disabled and queries go to the bare model.

To use full English Wikipedia instead, point the same pipeline at
`enwiki-latest-pages-articles.xml.bz2` (~22 GB compressed; indexing takes hours).

## Notes

- The model's context window is 4,096 tokens. Each query is stateless (no
  conversation carry-over), which keeps fact-check retrieval from overflowing it.
- Everything runs on-device; no network access at query time.
