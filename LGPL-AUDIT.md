# LGPL-Oriented libVLC Rebuild Audit

Date: 2026-05-10

Scope: the local ignored `Vendor/libvlc.xcframework` rebuilt from VLC commit
`c833c4be0` by `./scripts/build-libvlc.sh --ios-only`.

This is an engineering audit for the fork's LGPL-oriented iOS dynamic-framework
rebuild. It is not legal advice.

## Build Configuration

- `scripts/build-libvlc.sh` invokes VLC's Apple build with `--enable-shared`.
- The patched VLC `extras/package/apple/build.conf` contains
  `--disable-gpl` and `--disable-gnuv3`.
- GPL-sensitive contribs are explicitly disabled: `dvdcss`, `dvdread`,
  `dvdnav`, `x264`, `x265`, `faad`/`faad2`, `dca`, `mpeg2`, and `postproc`.
- Scan command:

```bash
rg -n -- "--enable-(gpl|gnuv3|dvdcss|dvdread|dvdnav|x264|x265|faad|dca|mpeg2|postproc)" scripts/build-libvlc.sh scripts/.build-libvlc/vlc/extras/package/apple/build.conf
```

Result: no matches.

```bash
rg -n -- "--disable-(gpl|gnuv3|dvdcss|dvdread|dvdnav|x264|x265|faad|dca|mpeg2|postproc)" scripts/build-libvlc.sh scripts/.build-libvlc/vlc/extras/package/apple/build.conf
```

Result: required disable options are present in both our wrapper script and the
patched VLC build config.

## Artifact Scan

Validation command:

```bash
./scripts/verify-libvlc-xcframework.sh Vendor/libvlc.xcframework
```

Result: dynamic iOS libVLC xcframework verification passed.

Additional scans:

```bash
find Vendor/libvlc.xcframework \( -name '*.a' -o -name '*.la' \) -print
find Vendor/libvlc.xcframework \( -path '*/Resources/share/doc' -o -path '*/Resources/share/man' \) -print
rg --files Vendor/libvlc.xcframework | rg -i "dvdcss|dvdread|dvdnav|x264|x265|faad|libdca|dca_plugin|mpeg2|postproc|gpl|gnuv3"
```

Results: no static archives, no libtool archives, no non-runtime VLC doc/man
resources, and no GPL-sensitive component filenames were found in the packaged
xcframework.

## Release Dry Run

Command:

```bash
./scripts/release.sh 0.0.0 --dry-run
```

Result: dry run completed without pushing. The stripped zip was 115 MB, and the
computed checksum was:

```text
2b0d634e2d673053a5eb86f9b0a98ba07a545f68ed9d5881a861837bd7a89924
```

Release URL shape:

```text
https://github.com/harukawu/SwiftVLC/releases/download/v0.0.0/libvlc.xcframework.zip
```

## Notes

- `Vendor/libvlc.xcframework` remains a local/release artifact and is not
  committed.
- The verifier now fails if future packaging reintroduces `.a`, `.la`,
  `Resources/share/doc`, `Resources/share/man`, or obvious GPL-sensitive
  component filenames.
