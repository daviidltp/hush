# Security / Seguridad

Hush is a password manager: security reports are the most valuable contribution.

**Do not open a public issue.** Report privately through
[Security → Report a vulnerability](https://github.com/daviidltp/hush/security/advisories/new).
Include the version or commit, the steps to reproduce and the impact. You will get an answer as soon as possible; this is a personal project maintained in spare time.

**No abras un issue público.** Avisa en privado desde
[Security → Report a vulnerability](https://github.com/daviidltp/hush/security/advisories/new),
con la versión o commit, los pasos para reproducirlo y el impacto.

## Scope

In scope: anything that exposes vault contents, keys or passwords — the KDBX reader/writer, Touch ID / Keychain, the browser extension, the native messaging bridge (`hush-bridge`), the menu bar helper, clipboard handling, temporary files and network requests.

Out of scope: attacks that require malware already running as your macOS user (it can read the screen and keystrokes anyway), and the known limitation that the browser extension is not yet signed by the browser stores.
