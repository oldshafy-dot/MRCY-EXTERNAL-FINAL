# Native registration and recovery checks

Run `bash checks/native/run.sh` on macOS with Xcode command-line tools. The IPA
workflow runs these checks before compiling the app. They compile the production
identity migration policy, transaction engine, data models and payload merge code.
The tests only write to their own temporary directory and never use a real app
container, production server, device key or license.

Covered cases:

- A three-function catalog keeps all three files before the release marker is
  committed, including users with zero, one or two previously trusted packages.
  Background library reads hide untrusted files without deleting in-flight writes.
- Reinstalling the same catalog restores missing files with their original IDs.
  These checks compile the production library and codec with a test-only key and
  trust list, and stub unrelated Keychain/workspace operations.
- Existing and legacy installation UUIDs retain their exact bytes and casing.
- A failed legacy copy retains the legacy identity.
- Missing, damaged or temporarily inaccessible identity storage does not silently
  replace a registered identity; a fresh install persists its UUID before use.
- Apply followed by Restore preserves the original file contents.
- A failure after the first Apply write rolls back locally.
- A partial Restore failure recovers the state from before Restore; a retry works.
- A damaged original backup is rejected before Restore changes any files.
- A failed rollback copy reports recovery required, keeps the prepared journal,
  and still attempts the other copies.
- A failed snapshot recovery keeps its recovery directory and original backups.

Physical-device checks still required: Keychain access after locking/unlocking,
an update signed by the same team, a changed signing identity, and file operations
on supported devices. These macOS checks do not exercise Secure Enclave enrollment
or prove survival of abrupt process termination, power loss, or storage failure.

Registration changes preserve the existing current/legacy key tags, Keychain
services and software-key fallback. No keys or tokens are rotated by this update.
If iOS denies access after re-signing under another team, the app cannot migrate
inaccessible Keychain entries; it requires the original signing identity or a
server-authorized re-enrollment.

Rollback performs no online authorization inside the transaction. Backup copies
are checked and synchronized before writes, and the journal is staged and synced
before its status changes. Backups are retained if recovery cannot complete.
This does not implement offline user-initiated Restore: the existing outer license
check still applies before starting Restore.
