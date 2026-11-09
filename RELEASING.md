# Release checklist

## Before a public release

- [ ] Confirm GitHub owner, repository name and visibility.
- [ ] Choose a license and add its actual text.
- [ ] Review every source file and Git history for private data and secrets.
- [ ] Keep data/, logs/, local settings and archives out of tracked files.
- [ ] Add screenshots containing synthetic goals, notes and deadlines.
- [ ] Enable and verify private vulnerability reporting.
- [ ] Add only verified, publication-approved receiving QR images and links.
- [ ] Verify that the separate Support page has current payment details.

## Validate

~~~sh
./test_native.sh
python3 test_app.py
python3 test_storage.py
./test_ui.sh
./build_native.sh --dmg
~~~

The native test runner targets the host architecture. Distribution currently
targets Apple Silicon (arm64), macOS 14+. Do not claim Intel support without
building and testing an Intel or universal distribution.

Test the final app on a clean user account: first launch, notifications,
reminders, menu bar, login items, keyboard editing and storage-error recovery.
Logic tests and compilation do not replace those checks.

## Signing and publication

The build script uses ad-hoc signing, not Developer ID signing or notarization.
Choose a clearly labeled unsigned preview or a Developer ID-signed, notarized
release. Do not disable Gatekeeper or describe an ad-hoc build as notarized.

After approval:
1. Set the release version and changelog.
2. Build and inspect the final app/DMG for bundled personal data.
3. Sign, notarize and staple if required by the selected distribution plan.
4. Publish source to the approved repository.
5. Attach binaries to a GitHub Release rather than committing them.
6. Add SHA-256 checksums, compatibility, changes and known limitations.
7. Verify the exact remote commit, CI status, release URL and downloads.

This checklist does not create a remote, release, payment link or license.
