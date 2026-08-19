# Working agreements

<!-- AGENTS.md sits next to this file and contains only `@CLAUDE.md`. They are
     two separate files: editing one no longer changes the other. The rules
     themselves live here, not there. -->

## Every code change

**Bump the version, then build.** Both, every time — not just when it feels
significant, and not only when I remember to ask.

1. **Bump.** Raise `MARKETING_VERSION` in
   `FaceFusion.xcodeproj/project.pbxproj`: patch for a fix (`1.0.4` → `1.0.5`),
   minor for a new feature. Raise `CURRENT_PROJECT_VERSION` by one alongside it.
   Each appears **6 times** — once per target per configuration — so change
   every occurrence or the app and its test bundles disagree about what they
   are.

2. **Build.** Not "it should compile":

   ```sh
   xcodebuild -project FaceFusion.xcodeproj -scheme Morphiqo \
              -configuration Debug \
              -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
   ```

   Use `-scheme`, never `-target`: SPM module maps are only generated for scheme
   builds.

Work that has not been built is not finished, and I do not want to hear it is
done until it has compiled.

If you touched anything under `Engine/`, run the tests too — the geometry, mask
and CPU↔GPU parity suites are the only thing standing between a subtle pixel
regression and a shipped one:

```sh
xcodebuild -project FaceFusion.xcodeproj -scheme Morphiqo \
           -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
           -only-testing:FaceFusionTests test
```

## Things that are load-bearing

- **`FaceFusion/` is a file-system-synchronised Xcode group.** Creating a file
  puts it in the build. Never hand-edit `project.pbxproj` to add sources.
- **The target and scheme are `Morphiqo`; the folder and the `.xcodeproj` are
  still `FaceFusion`.** That is deliberate — renaming the synchronised group
  would mean moving every source file. `-project FaceFusion.xcodeproj -scheme
  Morphiqo` is the correct pairing, not a mistake to tidy up.
- **The numbers in `Engine/Pipeline/` are validated against a Python/OpenCV
  ground truth.** Warp templates, normalisation constants, the emap projection's
  divisor, blend weights, mask feathering — none of it is a free parameter. If a
  change moves them, `GeometryTests` should fail; if it does not, the test is
  wrong too.
- **Every Metal kernel has a CPU twin and they must agree.** They are
  interchangeable at runtime, so a divergence shows up as a video that flickers
  when a frame falls back. Change one, change the other, and check
  `MetalParityTests` still passes.
- **`SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY` is on.** A file that uses
  `EngineLog` needs its own `import os`; inheriting it transitively no longer
  works.
- **The engine's concurrency shape matters.** Inference runs concurrently;
  anything that replaces engine state (`prepare`, `analyzeSource`,
  `setReferenceFaces`, unloading) runs as a barrier. Adding a method that mutates
  pipeline state without a barrier is a data race with in-flight frames.

## The app is published

Morphiqo is on the App Store and people have it installed. Every change has to
be one an existing install can *upgrade into*: the first launch after an update
starts with whatever the previous version left on the device, and "works on a
clean install" is not the bar.

- **Never remove a product id from `StoreManager.productIDs`.** People have
  paid for these — the subscriptions and the lifetime unlock alike — and that
  array is not a list of what to sell. It is the entitlement allowlist:
  `refreshEntitlements()` grants Pro only when a verified transaction's
  `productID` appears in it. Delete an id and every customer holding that
  product loses Pro at the next launch, silently. No error, no crash, and
  nothing Restore Purchases can recover — the transaction is still valid and
  the app has simply stopped recognising it. A subscriber is still being
  charged for it. **Add to that array; never subtract from it.**

  This holds when a product is *retired*, which is the case that tempts you.
  Retiring is a dashboard action: **Remove from Sale** in App Store Connect
  stops new purchases everywhere, including in builds already installed, and
  leaves every existing owner entitled. `Product.products(for:)` quietly omits
  an id the store will not sell, so the paywall stops offering it on its own
  with no code change at all. Do not delete the product in App Store Connect
  either — removal from sale is reversible and deletion is not, and the id is
  still doing entitlement work for the people who bought it.

  The same four ids are declared in the `Mac` repository and gate the same
  purchases: the two apps share a bundle identifier and an App Store record, so
  one Apple ID purchase unlocks both. The arrays have to stay in step, and
  dropping an id from one repository revokes Pro on that platform while leaving
  it working on the other — harder to notice than doing it in both.

  `README.md` covers the rest of the shape this constraint takes, including why
  the paywall and the entitlement gate read from two different places and what
  that means for adding a plan.

- **`UserDefaults` written by an older build.** Register new preferences with
  `register(defaults:)` and read them through that, so an absent key reads as
  the intended default rather than `false` or `0`. Never change what an existing
  key means, and never reuse one for a different type.
- **The model library on disk.** `models.json` is content-addressed. Adding an
  entry is safe and costs an existing user nothing until they choose to download
  it; changing an entry's digest makes the copy they already have stale and
  charges them the download again. The sweep deletes whatever the manifest no
  longer claims, so work out what a rename would reclaim before renaming
  anything.
- **Derived caches keyed by what you are changing.** The Core ML compile cache is
  keyed by model file name — a change that renames model files silently spends
  the whole compile cost on the next launch.
- **Anything persisted or decoded.** Saved settings, the onboarding flag, the
  successful-save count behind the review prompt. The `Codable` engine types are the sharp edge: a new field
  needs a default so an older blob still decodes, and a removed or renamed one
  has to be tolerated rather than assumed gone.

If a change genuinely cannot be made upgrade-safe, say so and describe the
migration it needs — do not ship something that only holds together on a device
that has never run the app before.

## iOS and macOS ship as one App Store record

Morphiqo is a **Universal Purchase**: app id `6797135085` is a single store
record covering iPhone, iPad, Mac and Vision, not two listings. Three things
follow, and the first two have already caused bugs:

- **`itunes.apple.com/lookup` returns one result with one version number, and
  it is the iOS one.** There is no `kind == "mac-software"` record to find —
  that kind belongs to apps with a *separate* Mac listing. Ours is
  `kind == "software"` with `MacDesktop-MacDesktop` in `supportedDevices`, the
  only public signal that the record contains a Mac build at all. Every other
  parameter was tried, `media=macSoftware` included, and they all return the
  same iOS record byte for byte.

- **That is why only iOS checks for updates.** The Mac had a check; it could
  only ever have compared a Mac against the iPhone's version number, so it was
  removed in 1.9.1 rather than left to be subtly wrong. The Mac App Store
  updates the app itself. Do not add one back without a source of truth for the
  macOS build's own version — and note that the obvious one, a version file on
  our website, is a manual step at every release and so a fact that will go
  stale the first time somebody forgets it.

- **A purchase on either platform unlocks both**, which is why the product
  identifiers are duplicated rather than being platform-specific.

## Privacy is a hard constraint, not a goal

This app makes two kinds of network request and no others:

1. **The model download**, in `Downloader`.
2. **The App Store version lookup**, in `UpdateChecker` — the launch check and
   the Check for Updates button in Settings share one `URLSession`. It sends
   the app's own store id and receives a version number. No device identifier,
   no install identifier, no usage, no media, and no request body for any of
   that to travel in.

No analytics, no telemetry, no crash reporting service, no "anonymous"
anything. If a change adds a `URLSession` outside those two, it is wrong.

The macOS app makes only the first of those; its version lookup was removed
in 1.9.1. Three documents make this claim on the app's behalf and are wrong the moment a
third request appears: the Privacy section of `SettingsView`, which the user
reads on screen; `/privacy` in the `Web` repository, which is the URL App Store
Connect points at; and `/support`. They are separate repositories and nothing
propagates between them, so a change here is three edits, by hand.

## The string catalog does not rewrite itself

`Localizable.xcstrings` used to change every time the project was opened in
Xcode and run, producing a git diff with no connection to anything you had just
done. **Three settings hold it still and all three are load-bearing.** Do not
change any of them without reading why.

1. **Every entry carries `"extractionState" : "manual"`.** That state means "a
   person put this here": Xcode's sync will not mark a manual entry stale and
   will not delete one, whichever of its extractors ran and however little of
   the source that extractor had managed to parse. This is the piece that
   actually holds. Point 2 removes the *compiler's* extractor, but the IDE runs
   a parser of its own that no build setting reaches — it wrote fresh data to
   DerivedData at 18:10 with the setting off since 17:51 — and one sync built on
   a half-built index marked **186 of 251 live iOS strings stale and deleted 11
   Mac entries outright**, a catalog the compiler had verified 248/248 in sync
   an hour earlier. A new entry added by hand must be marked manual too;
   `Tools/check-strings.py --fix` adopts any that are not.

2. **`SWIFT_EMIT_LOC_STRINGS = NO` on every target.** With it on, each build
   extracted string literals from the source and wrote the result back into the
   catalog *in the source tree*. `xcodebuild` from the terminal never did this,
   so a CLI-only session could drift for weeks and then dump the backlog the
   first time somebody opened the IDE.

3. **`STRING_CATALOG_GENERATE_SYMBOLS = NO` on the app target.** Manual entries
   take part in Swift symbol generation, and several keys here collide once they
   do: `Face swapper` against `Face Swapper`, `Remove %@` against `Remove %@?`,
   `Remove all models` against `Remove all models?`, `SETTINGS` against
   `Settings…`, and `%lld%%`, which yields no legal identifier at all. With
   symbols on, point 1 fails the build outright. Nothing in either app
   references a generated symbol, so switching them off costs nothing — but if
   anything ever does, it is these collisions that have to be resolved first.

**None of this changes what ships.** The catalog is still compiled into
`.lproj/Localizable.strings` by a separate build step; verified by building both
apps and reading the strings back out of `Morphiqo.app`, every language
present and unchanged in count. What is lost is only the automatic *authoring*
of new entries, and the IDE's own reporting of missing or dead strings — both of
which move to the tool below.

There was a fourth cause, and it was self-inflicted: an early version of
`Tools/check-strings.py` consumed the following entry's indentation when
deleting one, leaving 32 entries across the two catalogs at column 0. Nothing
fails when that happens — it is still valid JSON, it still parses, it still
builds, it still ships — so it survived review and got committed, and Xcode
reformatted the file on every single sync to put it back. If a catalog diff ever
turns out to be pure whitespace, look for that before looking anywhere else.

```sh
Tools/check-strings.py           # report drift, exit 1 if any
Tools/check-strings.py --fix     # delete dead entries, adopt entries as manual
```

It builds into its own DerivedData path with extraction forced back on and reads
the compiler's `.stringsdata`, so the answer is the extractor's rather than a
guess. That matters: a regex over the source cannot tell `Text("swap")` from the
word "swap" inside an identifier, and a scan that tried it left eight dead
entries behind while deleting two live ones. It also ignores `.stringsdata`
belonging to files that no longer exist — DerivedData keeps those forever, and
they make deleted strings look alive.

Two things it reports are worth acting on immediately:

- **MISSING** — in the code, not in the catalog. It renders English to every
  reader whose language the app otherwise speaks, and nothing fails to build.
- **missing a translation** — in the catalog with no value for one of the nine
  shipped languages (`de`, `es`, `fr`, `it`, `ja`, `ko`, `pt-BR`, `zh-Hans`,
  `zh-Hant`). Same outcome.

The build directory it creates is around 600 MB–1 GB and is git-ignored; delete
`.strings-check/` when you want the space back.

## Git

**Never commit on your own.** Do not run `git commit`, `git push`, `git tag`, or
anything else that writes to history unless I ask for it in that same turn.
Finishing a task, getting a green test run, or updating docs is not a request to
commit — leave the work in the tree and tell me what changed. Ask if you think a
commit is warranted; do not assume.

The same goes for anything else that rewrites or discards work, whether or not
it creates a commit: `git commit --amend`, `rebase`, `reset --hard`,
`checkout --` over modified files, `stash drop`, `clean -fd`, `push --force`.
Ask first, every time.

"I asked in that same turn" means I said so. It is not implied by my asking you
to finish a feature, fix a test, or tidy something up, and a previous commit I
approved does not authorise the next one.

### Work lands on `main`

When I do ask for a commit, the change belongs on `main` by the end of it:
branch, commit, merge back with `--no-ff`, and push `main` to the remote. Do not
leave finished work parked on a feature branch waiting for a pull request unless
I ask for one — a branch nobody merges is a change nobody has. Push the branch
too, so the history of how it landed survives.

### The commit is mine, and so is the name on it

When I ask you to commit, **the author and the committer are me, not you.** Take
the identity from the repository's own configuration — `git config user.name`
and `git config user.email`, currently `Ethan <lisen8018@gmail.com>` — and do
nothing that changes it:

- **Do not pass `--author`.** Do not set `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`,
  `GIT_COMMITTER_NAME` or `GIT_COMMITTER_EMAIL`.
- **Never put an assistant, bot or tool address in either field.**
  `noreply@anthropic.com`, `claude@…`, `bot@…`, `*@users.noreply.github.com`
  and anything similar are all wrong, in the author field and the committer
  field alike.
- **No `Co-Authored-By:` trailer for an AI**, and no second author of any kind.
- **No "Generated with Claude Code", "🤖", or any tool named anywhere** in the
  subject, body or trailers.

If `user.name` or `user.email` is unset, stop and ask me. Do not guess, and do
not let git fall back to the `user@hostname` identity it derives on its own —
a commit authored by `easonsmith@Mac.local` is as wrong as one authored by a
model.

After committing, check it actually landed as me:

```sh
git log -1 --format='%an <%ae> | %cn <%ce>'
```

This holds however the commit is made — the CLI, the VS Code Source Control
panel, or a generated message — and it holds for pull request titles and bodies,
issue comments and release notes too. Write in my voice: what changed and why.

The message itself should be thorough. `.vscode/git-commit-instructions.md` is
the standard this repository holds commit messages to; follow it when you write
one, so a message you draft and one the editor generates read the same.
