# ASign

The strongest, fastest on-device iOS IPA signer.

ASign is a complete signing workstation for iOS: import apps from anywhere,
sign them with your own certificates, inject tweaks, automate updates, and
install — all on-device, without a computer.

Built on the Feather lineage, redesigned and extended with an automation
engine, a tweak vault, a wireless Web Manager, encrypted backups, and a
liquid-glass interface.

## Features

- **Signing pipeline** — full IPA import, sign, and export powered by Zsign,
  with APFS clonefile fast paths and batch signing.
- **Signing options** — bundle identifier, display name, version, entitlements,
  Info.plist overrides, keychain isolation, PPQ protection, injection paths,
  extension targeting, appearance and minimum-OS rewrites, Liquid Glass
  experiments, ElleKit substrate replacement, and more.
- **Tweak Vault** — a persistent tweak library with folders, per-app
  auto-inject rules, dependency analysis, and extraction from existing IPAs.
- **Automation** — automatic update checks with per-app controls, background
  signing queue, certificate self-heal (re-signs apps before their certificate
  expires), and charging-only installs.
- **Certificate health** — expiry rings, revocation checks, one-tap renew-all,
  and per-app certificate pinning.
- **App Store** — browse AltStore sources, version history, screenshots,
  news, permissions, and one-tap downloads.
- **Web Manager** — transfer apps, tweaks, and certificates to and from your
  device over your local network from any browser.
- **Files** — a full document browser with plist/hex/text editors, extraction,
  and IPA repacking.
- **Installation** — fully-local HTTPS server (itms-services), semi-local
  mode, or direct device installation via a pairing file.
- **Live Activities** — download and signing progress on the Lock Screen and
  in the Dynamic Island, with pause/resume controls.
- **Data** — encrypted backup and restore, storage manager, activity timeline,
  rotating file logs.
- **Security** — Face ID lock, revocation screening, constant-time authenticated
  Web Manager.

## Build

Requires Xcode 26 or newer.

```sh
make deps     # fetch loopback TLS identity for the install server
make          # build packages/ASign.ipa (unsigned; ad-hoc signed)
```

The GitHub Actions workflow builds and publishes `ASign.ipa` on every push to
`main`.

## License

GPL-3.0 — see [LICENSE](LICENSE). ASign builds on the work of the Feather
contributors and the broader sideloading community.
