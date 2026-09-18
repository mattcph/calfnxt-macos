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
# Profile name should match NOTARY_PROFILE in .env.local (default: com.calfNXT)
xcrun notarytool store-credentials "com.calfNXT" \
  --apple-id "<apple-id>" \
  --team-id "<TEAMID>" \
  --password "<app-specific-password>"
```

If you already stored a profile for another product line (e.g. `com.auxVST`),
you can reuse it; the profile only holds your Apple ID / team / password:
`NOTARY_PROFILE=com.auxVST` in `.env.local`.

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
make -C port release                      # sign all 25 → dist/ + install
make -C port release PLUGIN=equalizer     # one plugin
make -C port release NOTARIZE=1           # sign + notarize + staple all 25
```

Or call the script directly with Make-style overrides:

```bash
port/tools/release.sh equalizer --notarize \
  CODE_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" \
  NOTARY_PROFILE=com.calfNXT
```

Output:

```text
port/build/VST3/Release/<Name>.vst3        # build tree (signed in place)
dist/<Name>.vst3                           # shipping copy (gitignored)
~/Library/Audio/Plug-Ins/VST3/<Name>.vst3  # installed copy
```



## Verify the signature

```bash
BUNDLE=dist/calfNXTEqualizer.vst3
codesign --verify --deep --strict --verbose=2 "$BUNDLE"
codesign -dv --verbose=4 "$BUNDLE" 2>&1 | grep -E "Authority|TeamIdentifier"
```

Confirm a Developer ID authority and your team id.

## What the script does per bundle

1. `codesign --force -s "$CODE_SIGN_IDENTITY" --timestamp --options runtime`
  (hardened runtime + secure timestamp are required by notarization).
2. `codesign --verify --deep --strict`.
3. With `--notarize`: `ditto` zip → `xcrun notarytool submit --wait` →
  `xcrun stapler staple` → `xcrun stapler validate` → `spctl -a -vv -t install`.
4. Copies the result to `dist/` and refreshes the installed copy.

**Rebuild or re-sign requires a new notarization and staple.**

## Notes

- The build uses the Xcode generator with manual code-sign style
(`SMTG_XCODE_MANUAL_CODE_SIGN_STYLE=ON`), so signing is a post-build
`codesign` step. Signing happens after the UI resources are embedded, so
the seal covers the whole bundle.
- The plug-in runs inside the DAW's process, so the host's entitlements
(including WebKit usage) apply.

