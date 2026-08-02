# Working agreements

<!-- AGENTS.md is a symlink to this file: one file, two names. Never write an
     `@CLAUDE.md` import into either of them — it resolves to itself and wipes
     this content. It has happened twice. -->

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

## Privacy is a hard constraint, not a goal

The only network request this app makes is the model download in `Downloader`.
No analytics, no telemetry, no crash reporting service, no "anonymous" anything.
If a change adds a `URLSession` anywhere else, it is wrong.

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
