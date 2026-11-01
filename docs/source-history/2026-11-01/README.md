# Superseded local source history

The accepted implementation is on `main`. This 53 KiB incremental bundle preserves
the exact local-only Git objects found before removing the original development
checkout: eight T3 checkpoint commits, two superseded commits, three trees and
five detached source blobs. It includes a synthetic container commit for detached
objects; that commit is an archive, not a product implementation.

The original checkout HEAD and index tree both match merged `main` at
`8dc8ccf971677b0c51cddf979861126441903105`. Checkpoint trees match published
parents. The earlier resource-profile commit was rewritten to retain the
operator's icon changes; its useful implementation is already merged. Detached
source alternatives and a README merge-conflict intermediate remain recoverable
without replacing accepted source. Exact identities, refs, tree matches and the
bundle SHA-256 are in [manifest.json](manifest.json).

Only source objects and Git metadata are included. Private settings, API keys,
runtime logs, model weights, installed runtimes and signed apps remain outside
Git. Live model quality, microphone/permission flows, Muse inference and Apple PCC
activation retain their separate acceptance gates in ST-311. Canaveral's embedded
runner inference is independently owned under ST-367 and does not depend on this
standalone app or API.

## Restore exact objects

Start from a fresh GitHub clone, which supplies the bundle's prerequisite objects:

```sh
git clone https://github.com/lucasilverentand/positronic.git positronic
cd positronic
shasum -a 256 docs/source-history/2026-11-01/local-source.bundle
git bundle verify docs/source-history/2026-11-01/local-source.bundle
git fetch docs/source-history/2026-11-01/local-source.bundle \
  '+refs/t3/*:refs/t3/*' '+refs/archive/*:refs/archive/*'
git fsck --full
```

Compare the checksum to `manifest.json`. Every original ref and reflog identity
listed there is then available to `git cat-file`, `git show` or a new branch.
The synthetic `refs/archive/local-source-objects` tree names detached blobs and
trees by their object IDs. Inspect those historical files with `git show` rather
than checking out the synthetic container as an application.

Refs: ST-311.
