import KDBXKit
import Testing
@testable import BovedaCore

@Suite struct BrowserMatchTests {
    @Test func sameSiteMatches() {
        #expect(BrowserMatch.matches(page: "https://github.com/login", entryURL: "github.com"))
        #expect(BrowserMatch.matches(page: "https://accounts.google.com/x", entryURL: "https://mail.google.com"))
        #expect(BrowserMatch.matches(page: "https://www.bbva.es", entryURL: "https://login.bbva.es/inicio"))
        #expect(BrowserMatch.matches(page: "https://shop.amazon.co.uk", entryURL: "amazon.co.uk"))
        #expect(BrowserMatch.matches(page: "https://sede.agenciatributaria.gob.es", entryURL: "agenciatributaria.gob.es"))
        #expect(BrowserMatch.site(of: "a.b.www.ck") == "www.ck")
        #expect(BrowserMatch.site(of: "x.foo.ck") == "x.foo.ck")
        #expect(BrowserMatch.matches(page: "https://a.www.ck", entryURL: "www.ck"))
        #expect(!BrowserMatch.matches(page: "https://otro.ck", entryURL: "www.ck"))
        // Dominios con tildes: lo escrito a mano coincide con el punycode que manda el navegador.
        #expect(Punycode.asciiHost("bücher.de") == "xn--bcher-kva.de")
        #expect(Punycode.asciiHost("españa.es") == "xn--espaa-rta.es")
        #expect(BrowserMatch.matches(page: "https://www.xn--bcher-kva.de/login", entryURL: "bücher.de"))
        #expect(!BrowserMatch.matches(page: "https://xn--bcher-kva.de", entryURL: "bucher.de"))
    }

    @Test func otherSitesDoNotMatch() {
        #expect(!BrowserMatch.matches(page: "https://evil-github.com", entryURL: "github.com"))
        #expect(!BrowserMatch.matches(page: "https://github.com.evil.io", entryURL: "github.com"))
        #expect(!BrowserMatch.matches(page: "https://amazon.co.uk", entryURL: "ebay.co.uk"))
        #expect(!BrowserMatch.matches(page: "chrome-extension://abc/popup.html", entryURL: "abc"))
        #expect(!BrowserMatch.matches(page: "https://github.com", entryURL: ""))
        #expect(!BrowserMatch.matches(page: "http://192.168.1.2", entryURL: "http://192.168.1.3"))
        // Webs de distintos dueños en un dominio compartido (Public Suffix List).
        #expect(!BrowserMatch.matches(page: "https://atacante.github.io", entryURL: "https://victima.github.io"))
        #expect(!BrowserMatch.matches(page: "https://otro.vercel.app/login", entryURL: "mi-app.vercel.app"))
        #expect(!BrowserMatch.matches(page: "https://evil.appspot.com", entryURL: "good.appspot.com"))
        #expect(!BrowserMatch.matches(page: "https://github.io", entryURL: "victima.github.io"))
        #expect(BrowserMatch.matches(page: "https://victima.github.io/x", entryURL: "victima.github.io"))
        // https guardado no se da a http; http guardado sí a http y a https.
        #expect(!BrowserMatch.matches(page: "http://bbva.es", entryURL: "https://bbva.es"))
        #expect(!BrowserMatch.matches(page: "http://bbva.es", entryURL: "bbva.es"))
        #expect(BrowserMatch.matches(page: "http://router.local", entryURL: "http://router.local"))
        #expect(BrowserMatch.matches(page: "https://router.local", entryURL: "http://router.local"))
    }

    @Test func additionalURLsCount() {
        var entry = KDBX.Entry.make(title: "Microsoft")
        entry.set(FieldKey.url, "https://login.live.com")
        entry.set("KP2A_URL_1", "https://outlook.com")
        #expect(BrowserMatch.matches(page: "https://outlook.com/mail", entry: entry))
        #expect(!BrowserMatch.matches(page: "https://gmail.com", entry: entry))
    }
}
