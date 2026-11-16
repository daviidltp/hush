import Foundation
import KDBXKit
import Testing
@testable import BovedaCore

@Suite struct SaveLoginTests {
    private func vault() throws -> Vault {
        var vault = try VaultTests.makeVault(in: try VaultTests.tempDir())
        let id = try #require(vault.root.entries.first?.uuid)
        vault.updateEntry(id) { $0.set(FieldKey.url, "https://github.com") }
        return vault
    }

    @Test func knownLoginIsNotOffered() throws {
        let vault = try vault()
        #expect(SaveLogin.decide(page: "https://github.com/login", user: "david", password: "s3creta", in: vault) == .known)
        // El usuario no distingue mayúsculas.
        #expect(SaveLogin.decide(page: "https://github.com/session", user: "David", password: "s3creta", in: vault) == .known)
    }

    @Test func changedPasswordOffersUpdate() throws {
        let vault = try vault()
        let id = try #require(vault.root.entries.first?.uuid)
        #expect(SaveLogin.decide(page: "https://github.com/login", user: "david", password: "otra", in: vault) == .update(id))
    }

    @Test func otherUserOrSiteIsNew() throws {
        let vault = try vault()
        #expect(SaveLogin.decide(page: "https://github.com/login", user: "ana", password: "s3creta", in: vault) == .new)
        #expect(SaveLogin.decide(page: "https://gitlab.com/login", user: "david", password: "s3creta", in: vault) == .new)
        // Lo guardado para https no cuenta en una página sin cifrar.
        #expect(SaveLogin.decide(page: "http://github.com/login", user: "david", password: "s3creta", in: vault) == .new)
    }

    @Test func updateKeepsHistory() throws {
        var vault = try vault()
        let id = try #require(vault.root.entries.first?.uuid)
        vault.updateEntry(id) { $0.set(FieldKey.password, "nueva", protected: true) }
        let entry = try #require(vault.locate(id)?.entry)
        #expect(entry.string(FieldKey.password) == "nueva")
        #expect(entry.history.last?.string(FieldKey.password) == "s3creta")
    }

    @Test func defaultsAndSameSite() {
        #expect(SaveLogin.defaultTitle(for: "https://accounts.google.com/signin?x=1") == "google.com")
        #expect(SaveLogin.defaultTitle(for: "https://ana.github.io/login") == "ana.github.io")
        #expect(SaveLogin.defaultURL(for: "https://www.bbva.es/login?next=/") == "https://bbva.es")
        #expect(SaveLogin.sameSite("https://mail.google.com", page: "https://accounts.google.com/x"))
        #expect(SaveLogin.sameSite("google.com", page: "https://accounts.google.com/x"))
        #expect(!SaveLogin.sameSite("https://bbva.es", page: "https://evil.com/login"))
        #expect(!SaveLogin.sameSite("", page: "https://evil.com/login"))
    }

    @Test func newEntryProtectsPassword() {
        let entry = SaveLogin.makeEntry(title: "github.com", user: "david", password: "x", url: "https://github.com", notes: "nota")
        #expect(entry.isProtected(FieldKey.password))
        #expect(entry.userName == "david" && entry.url == "https://github.com" && entry.notes == "nota")
        #expect(entry.kind == .login)
    }

    @Test func neverAskIsPerSite() {
        #expect(SaveLogin.siteKey(for: "https://accounts.google.com/signin") == "google.com")
        #expect(SaveLogin.siteKey(for: "https://www.bbva.es/") == "bbva.es")
        #expect(SaveLogin.siteKey(for: "https://ana.github.io/x") == "ana.github.io")
        #expect(SaveLogin.siteKey(for: "chrome-extension://abc/popup.html") == nil)
        #expect(SaveLogin.adding("google.com", to: ["bbva.es", "google.com"]) == ["bbva.es", "google.com"])
        #expect(SaveLogin.adding("amazon.es", to: ["bbva.es"]) == ["amazon.es", "bbva.es"])
    }
}
