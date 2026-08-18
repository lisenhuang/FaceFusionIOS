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

  The same three ids are declared in the `Mac` repository and gate the same
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
  `kind == "software"` with `MacDesktop-MacDesktop` in `supportedDevices`, which
  is the only public signal that the record contains a Mac build at all. An iPad
  app merely runnable on Apple silicon has neither, which is what makes the
  signal usable. `UpdateChecker.parse` depends on exactly this.

- **Keep `MARKETING_VERSION` identical in both projects.** Because one number is
  published for the whole record, the Mac's Check for Updates can only be right
  while the two platforms are released at the same version. They diverged once
  already — iOS 1.8.1 against Mac 1.8.0 — and a Mac on 1.8.0 would have been
  told 1.8.1 was available when no new Mac build existed. The build numbers may
  differ; the marketing version may not.

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

Three documents make this claim on the app's behalf and are wrong the moment a
third request appears: the Privacy section of `SettingsView`, which the user
reads on screen; `/privacy` in the `Web` repository, which is the URL App Store
Connect points at; and `/support`. They are separate repositories and nothing
propagates between them, so a change here is three edits, by hand.

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
