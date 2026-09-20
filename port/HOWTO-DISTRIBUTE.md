# Distribute calfNXT plug-ins (macOS VST3)

Applies to all 25 calfNXT bundles built by `port/Makefile`
(`calfNXTEqualizer.vst3`, `calfNXTCompressor.vst3`, …).

**Local DAW testing uses ad-hoc signing**: `make -C port install` produces
bundles that load on the build machine. This document is the distribution
path: bundles that pass Gatekeeper on *other* Macs require Developer ID
signing + notarization + stapling.

## Prerequisites

1. Install a **Developer ID Application** certificate in the login keychain.
2. Create an **app-specific password** at
  [appleid.apple.com](https://appleid.apple.com) → Sign-In and Security →
   App-Specific Passwords.
3. Store notary credentials **once** in the keychain:

```bash
# Profile name should match NOTARY_PROFILE in .env.local
xcrun notarytool store-credentials "com.yourNotaryProfile" \
  --apple-id "<apple-id>" \
  --team-id "<TEAMID>" \
  --password "<app-specific-password>"
```

The profile is just a keychain name for your Apple ID / team / password. Any
name works, and you can reuse one profile across product lines (calfNXT,
auxVST, …) — set `NOTARY_PROFILE=com.yourNotaryProfile` in `.env.local`.

1. Confirm the signing identity:

```bash
security find-identity -v -p codesigning
```



## Build for local use

Ad-hoc signed. Installs into `~/Library/Audio/Plug-Ins/VST3/`.

```bash
make -C port install
```



## Build a signed release

Copy `[.env.local.example](../.env.local.example)` to repo-root `.env.local` and fill in your Developer ID values (gitignored). Then when in repo-root:

```bash
make -C port release VERSION=2.3.1.1                # clean rebuild + sign all 25
make -C port release VERSION=2.3.1.1 NOTARIZE=1     # + notarize + staple all 25
```

The port version (e.g. `2.3.1.1`) is **required**. It is baked into the
bundles (`CFBundleShortVersionString`) and used for the local backup:

```text
Releases/2.3.1.1/<Name>.vst3            # versioned backup (repo root, gitignored)
Releases/calfNXT-macOS-2.3.1.1.zip      # ready to attach to a GitHub Release
~/Library/Audio/Plug-Ins/VST3/<Name>.vst3  # installed copy
```

(`dist/` stays the scratch/test area; `Releases/` keeps every version beside
the previous ones, like auxVST.)

`tools/release.sh` always wipes `port/build/VST3/Release` and the in-tree
Xcode object files before rebuilding, so a notarized run can never staple
stale products from an earlier submodule.

Or call the script directly with Make-style overrides:

```bash
port/tools/release.sh 2.3.1.1 --notarize \
  CODE_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" \
  NOTARY_PROFILE=com.yourNotaryProfile
```



## Verify the signature

```bash
BUNDLE=Releases/2.3.1.1/calfNXTEqualizer.vst3
codesign --verify --deep --strict --verbose=2 "$BUNDLE"
codesign -dv --verbose=4 "$BUNDLE" 2>&1 | grep -E "Authority|TeamIdentifier"
```

Confirm a Developer ID authority and your team id.

## What the script does

1. Wipes `port/build/VST3/Release` and the in-tree Xcode objects, then
   rebuilds all 25 plugins with `-DCALFNXT_PORT_VERSION=<version>`.
2. `codesign --force -s "$CODE_SIGN_IDENTITY" --timestamp --options runtime`
   (hardened runtime + secure timestamp are required by notarization).
3. `codesign --verify --deep --strict`.
4. With `--notarize`: one `ditto` zip of all bundles →
   `xcrun notarytool submit --wait` → `xcrun stapler staple` +
   `xcrun stapler validate` per bundle → `spctl -a -vv -t install`.
5. Copies the result to `Releases/<version>/`, zips the suite to
   `Releases/calfNXT-macOS-<version>.zip`, and refreshes the installed copies.

**Rebuild or re-sign requires a new notarization and staple.**

## Notes

- The build uses the Xcode generator with manual code-sign style
(`SMTG_XCODE_MANUAL_CODE_SIGN_STYLE=ON`), so signing is a post-build
`codesign` step. Signing happens after the UI resources are embedded, so
the seal covers the whole bundle.
- The plug-in runs inside the DAW's process, so the host's entitlements
(including WebKit usage) apply.

