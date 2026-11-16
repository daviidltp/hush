import Foundation
import KDBXKit
import Testing
@testable import BovedaCore

@Suite struct ImportTests {
    private func read(_ text: String) throws -> ImportResult { try Importer.read(Data(text.utf8)) }

    @Test func csvHandlesQuotesCommasAndNewlines() {
        let rows = Importer.csvRows("a,\"b, c\",\"d \"\"e\"\"\"\r\n\"multi\nlínea\",,x\n")
        #expect(rows == [["a", "b, c", "d \"e\""], ["multi\nlínea", "", "x"]])
    }

    @Test func browserCSV() throws {
        let result = try read("""
        name,url,username,password,note
        github.com,https://github.com/login,david,s3creta,
        ,https://www.example.com/,ana,1234,nota con, coma
        """)
        #expect(result.format == .chromeCSV)
        #expect(result.items.count == 2)
        #expect(result.items[1].title == "example.com")
        #expect(result.items[1].notes == "nota con")
    }

    @Test func browserCSVWithQuotedNote() throws {
        let result = try read("name,url,username,password,note\nweb,https://a.com,u,p,\"nota, con coma\"\n")
        #expect(result.items.first?.notes == "nota, con coma")
    }

    @Test func passwordsAppCSVKeepsTOTP() throws {
        let result = try read("""
        Title,URL,Username,Password,Notes,OTPAuth
        GitHub,https://github.com,david,s3creta,,otpauth://totp/GitHub:david?secret=JBSWY3DPEHPK3PXP&issuer=GitHub
        """)
        #expect(result.format == .appleCSV)
        let entry = try #require(result.items.first).makeEntry()
        #expect(TOTP.from(entry) != nil)
    }

    @Test func onePasswordCSV() throws {
        let result = try read("""
        Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes
        Banco,https://banco.es,12345678Z,clave,,true,false,"finanzas,casa",
        """)
        #expect(result.format == .onePasswordCSV)
        let item = try #require(result.items.first)
        #expect(item.favorite && item.tags == ["finanzas", "casa"])
        #expect(item.makeEntry().isFavorite)
    }

    @Test func firefoxCSVUsesHostAsTitle() throws {
        let result = try read("""
        "url","username","password","httpRealm","formActionOrigin","guid","timeCreated","timeLastUsed","timePasswordChanged"
        "https://accounts.google.com","david@gmail.com","abc","","https://accounts.google.com","{1}","1700000000000","1700000000000","1700000000000"
        """)
        #expect(result.format == .firefoxCSV)
        #expect(result.items.first?.title == "accounts.google.com")
        #expect(result.items.first?.created == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func protonCSVKeepsEmailAndSecretKey() throws {
        let result = try read("""
        name,url,email,username,password,note,totp,createTime,modifyTime,vault
        Correo,https://mail.example.com,ana@example.com,ana,pw,,JBSWY3DPEHPK3PXP,1700000000,1700000000,Personal
        """)
        #expect(result.format == .protonCSV)
        let item = try #require(result.items.first)
        #expect(item.userName == "ana" && item.fields.contains { $0.name == "Email" && $0.value == "ana@example.com" })
        let entry = item.makeEntry()
        #expect(entry.string(FieldKey.otp).hasPrefix("otpauth://totp/") && TOTP.from(entry) != nil)
    }

    @Test func bitwardenCSVWithFoldersNotesAndFields() throws {
        let result = try read("""
        folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp
        Trabajo,1,login,Jira,,"PIN: 1234
        Equipo: azul",0,https://jira.example.com,david,pw,
        ,,note,Wifi casa,clave del router,,0,,,,
        """)
        #expect(result.format == .bitwardenCSV)
        #expect(result.items.count == 2)
        #expect(result.items[0].folder == ["Trabajo"] && result.items[0].favorite)
        #expect(result.items[0].fields.map(\.name) == ["PIN", "Equipo"])
        #expect(result.items[1].kind == .note && result.items[1].notes == "clave del router")
    }

    @Test func bitwardenJSONLoginsCardsAndFolders() throws {
        let json = """
        {"encrypted": false,
         "folders": [{"id": "f1", "name": "Finanzas/Tarjetas"}],
         "items": [
           {"type": 1, "name": "GitHub", "favorite": true, "folderId": null, "notes": null,
            "login": {"username": "david", "password": "s3creta", "totp": "JBSWY3DPEHPK3PXP",
                      "uris": [{"uri": "https://github.com"}, {"uri": "https://gist.github.com"}]},
            "fields": [{"name": "Recuperación", "value": "abc-def", "type": 1}]},
           {"type": 3, "name": "Visa", "folderId": "f1",
            "card": {"cardholderName": "David López", "brand": "Visa", "number": "4111111111111111", "expMonth": "3", "expYear": "2029", "code": "123"}},
           {"type": 2, "name": "Nota", "notes": "secreto"}
         ]}
        """
        let result = try read(json)
        #expect(result.format == .bitwardenJSON && result.items.count == 3)
        let card = try #require(result.items.first { $0.kind == .card }).makeEntry()
        #expect(card.kind == .card && card.string(CardField.expiry) == "03/29" && card.isProtected(CardField.number))
        let login = result.items[0].makeEntry()
        #expect(login.string("URL 2") == "https://gist.github.com" && login.isProtected("Recuperación"))
        #expect(result.items[1].folder == ["Finanzas", "Tarjetas"])
    }

    @Test func encryptedExportIsRejected() {
        #expect(throws: ImportError.encrypted) { try read(#"{"encrypted": true, "items": []}"#) }
        #expect(throws: ImportError.unrecognized) { try read("a,b\n1,2\n") }
    }

    @Test func importCreatesGroupsSkipsDuplicatesAndSurvivesSave() throws {
        let dir = try VaultTests.tempDir()
        var vault = try VaultTests.makeVault(in: dir)
        let result = try read("""
        folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp
        Trabajo/Equipo,,login,Jira,,,0,https://jira.example.com,david,pw,
        ,,login,GitHub,,,0,,david,s3creta,
        """)
        let known = vault.importSignatures
        let fresh = result.items.filter { !known.contains($0.signature) }
        #expect(fresh.map(\.title) == ["Jira"], "GitHub ya estaba en la base de prueba")
        let top = vault.importItems(fresh, intoGroupNamed: "Importado")
        try vault.save(backups: BackupStore(directory: dir.appendingPathComponent("copias")))
        let reopened = try Vault.open(url: vault.url, unlock: UnlockData(masterPassword: "prueba"))
        let group = try #require(reopened.root.group(top))
        #expect(group.groups.first?.name == "Trabajo" && group.groups.first?.groups.first?.entries.first?.title == "Jira")
    }
}
