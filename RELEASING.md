# Versioning and releases

## Version number and maturity

Viby uses numeric `MAJOR.MINOR.PATCH` only. Tags are `vX.Y.Z`; the `v` belongs
to the Git tag, not the version stored in application manifests.

The initial release is **0.0.1**, labeled **Pre-alpha**. It is a source-only
development snapshot. The old `0.1.0` scaffold values were never tagged or
released.

Maturity is communicated in the README, changelog and GitHub release:

| Stage | Meaning |
| --- | --- |
| Pre-alpha | Core architecture and functionality are still being built; source snapshots may be incomplete. |
| Alpha | The core local-engine-to-Windows journey exists and can be evaluated, with known rough edges. |
| Beta | Intended release functionality exists; wider compatibility and regression work remain. |
| Release candidate | The candidate meets its release gates; remaining changes should address release-blocking defects. |
| Stable | The published scope, validation and compatibility commitments are ready for users. |

The labels do not add suffixes to version numbers. A GitHub release can be
marked **pre-release** while its version remains simply `0.0.1`.

While major is zero, interfaces and settings may change. Use patch increments
for compatible fixes and useful development snapshots; use a minor increment
for a substantial capability or breaking change, and describe compatibility
changes explicitly. Version 1.0.0 requires a declared compatibility contract.
After 1.0, follow SemVer's major/minor/patch compatibility rules.

## Changelog format

Keep `Unreleased` at the top, followed by releases newest first. Each released
version has one dated heading: `## [X.Y.Z] - YYYY-MM-DD`.

Use only relevant groups: `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`,
and `Security`. A release may also include `Known limitations`, especially
during pre-alpha.

Write the observable change and why it matters. Group related commits into
one useful entry; do not paste a Git commit log. Planned features belong in
[ROADMAP.md](ROADMAP.md), not under shipped additions.

Released notes and tags are immutable. Correct a material error in a new
release or add an explicit erratum; do not silently move an existing tag.

## Version source and commands

`package.json` is the version authority. The helper synchronizes its mirrors in
`package-lock.json`, `src-tauri/Cargo.toml`, `src-tauri/Cargo.lock`, and
`src-tauri/tauri.conf.json`. It adds no dependencies.

Run in WSL:

```sh
npm run check:version
npm run version:set -- 0.0.2
```

The setter updates metadata only. It does not create a commit, tag or release.
It rejects suffixes, leading zeroes and backwards version changes. After
setting a new version, add its dated changelog entry before checking/building.

## Preparing a source snapshot

1. Finish and review the intended changes.
2. Select the next numeric version with `npm run version:set -- X.Y.Z`.
3. Move completed `Unreleased` items into a dated release section, keep
   `Unreleased` for future changes, and update changelog comparison links.
4. State the maturity, distribution type and important limitations.
5. Validate versions, frontend and Windows Rust checks on the release commit.
6. Commit and push the reviewed snapshot; wait for its CI checks to pass.
7. Create an annotated tag, then publish a GitHub pre-release using the curated
   changelog notes.

For example, after preparing version 0.0.2:

```sh
npm run check:version -- --tag v0.0.2
npm run build
npm run --silent release:notes -- 0.0.2 > /tmp/viby-release-notes.md
```

On Windows, run `scripts/run-rust-gates.ps1` and
`scripts/run-release-build.ps1`. Native UI/microphone/end-to-end checks remain
separate from CI's hardware-free unit tests.

After the release commit is reviewed, pushed and verified:

```sh
git tag -a v0.0.2 -m "Viby 0.0.2 - pre-alpha source snapshot"
git push origin v0.0.2

gh release create v0.0.2 --verify-tag --prerelease --latest=false \
  --title "Viby 0.0.2 - Pre-alpha" \
  --notes-file /tmp/viby-release-notes.md
```

GitHub provides source archives for the tag. Do not attach an unverified local
executable or present source archives as an installer. The package's
`private: true` setting prevents accidental npm publication; it does not make
the GitHub repository private.

## Before publishing an installable application

Complete the [roadmap's release gates](ROADMAP.md#first-usable-release-checklist):
configurable user-managed local AI integration, safe insertion, native
end-to-end/privacy verification, clean-machine installer validation,
prerequisite instructions, version/checksum provenance and rollback guidance.

Review dependency notices and the distribution/signing decision before
shipping binaries. Source snapshots do not close those gates.

References: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
[SemVer](https://semver.org/spec/v2.0.0.html), and
[Tauri version configuration](https://v2.tauri.app/reference/config/#version).
