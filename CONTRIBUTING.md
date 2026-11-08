# Contributing / Contribuir

Thanks for helping. Hush is a personal project maintained in spare time, so reviews may take a while.

- **Discuss first** for anything big (new features, dependencies, network requests): open an issue.
- **Small, focused pull requests.** They are merged with *squash*, so one PR = one commit in `main`.
- `swift test` must pass (CI runs it on macOS). The KeePassXC compatibility tests only run if KeePassXC is installed locally.
- The app UI is in **Spanish**; code comments are mostly Spanish too. English is fine in issues and PRs.
- Never test with a real vault. Create a test database (for example `Demo.kdbx` with password `demo1234`).
- Security-sensitive code (vault reading/writing, crypto, Touch ID, `Extension/`, `Sources/HushBridge`, `Sources/Boveda/BrowserBridge.swift`) gets an extra review. Explain the security impact in the PR.
- No telemetry, no analytics, no new third-party services.
- The UI never names other password managers.

Build and run: see the [README](README.md#build).

---

Gracias por ayudar. Abre un issue antes de cambios grandes, haz PR pequeñas (se fusionan con *squash*), comprueba que `swift test` pasa y no pruebes nunca con una base real.
