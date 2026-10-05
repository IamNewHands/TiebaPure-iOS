import XCTest
@testable import TiebaPure

final class AuthSessionTests: XCTestCase {
    override func tearDown() {
        AuthMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testMemoryAccountStoreSavesLoadsAndClearsOneAccount() async throws {
        let service = MemoryAccountStoreService()
        let store = AccountStore(service: service)
        let account = Account(
            uid: "42",
            name: "raw",
            displayName: "Raw",
            portrait: "portrait",
            bduss: "bduss",
            stoken: "stoken",
            baiduID: "baiduid",
            tbs: "tbs"
        )

        try await store.save(account)
        let loadedAccount = try await store.load()
        XCTAssertEqual(loadedAccount, account)

        try await store.clear()
        let clearedAccount = try await store.load()
        XCTAssertNil(clearedAccount)
    }

    func testConditionalAccountMetadataSaveCannotRecreateLoggedOutSession() async throws {
        let store = AccountStore(service: MemoryAccountStoreService())
        let account = Self.makeAccount()
        try await store.save(account)
        try await store.clear()

        do {
            try await store.updateDisplayName("旧页面昵称", forSession: account.sessionIdentity)
            XCTFail("注销后的旧页面不应重新写回账号")
        } catch {
            XCTAssertEqual(error as? AccountStoreError, .sessionChanged)
        }
        let storedAccount = try await store.load()
        XCTAssertNil(storedAccount)
    }

    func testConditionalAccountMetadataSaveCannotReplaceNewerLogin() async throws {
        let store = AccountStore(service: MemoryAccountStoreService())
        let oldAccount = Self.makeAccount()
        var newAccount = oldAccount
        newAccount.uid = "84"
        newAccount.name = "new-login"
        newAccount.displayName = "新账号"
        try await store.save(oldAccount)
        try await store.save(newAccount)

        do {
            try await store.updateDisplayName("旧账号修改", forSession: oldAccount.sessionIdentity)
            XCTFail("旧页面不应覆盖新的登录账号")
        } catch {
            XCTAssertEqual(error as? AccountStoreError, .sessionChanged)
        }
        let storedAccount = try await store.load()
        XCTAssertEqual(storedAccount, newAccount)
    }

    func testMetadataUpdateRejectsOldSameUIDSessionAndPreservesNewCredentials() async throws {
        let store = AccountStore(service: MemoryAccountStoreService())
        let oldAccount = Self.makeAccount()
        var refreshedAccount = oldAccount
        refreshedAccount.bduss = "new-bduss"
        refreshedAccount.stoken = "new-stoken"
        refreshedAccount.baiduID = "new-baiduid"
        refreshedAccount.tbs = "new-tbs"
        refreshedAccount.displayName = "刷新前昵称"
        try await store.save(oldAccount)
        try await store.save(refreshedAccount)

        do {
            try await store.updateDisplayName("资料页新昵称", forSession: oldAccount.sessionIdentity)
            XCTFail("旧会话不应更新同 UID 新登录的元数据")
        } catch {
            XCTAssertEqual(error as? AccountStoreError, .sessionChanged)
        }

        var storedAccount = try await store.load()
        XCTAssertEqual(storedAccount, refreshedAccount)

        try await store.updateDisplayName(
            "资料页新昵称",
            forSession: refreshedAccount.sessionIdentity
        )
        var expectedAccount = refreshedAccount
        expectedAccount.displayName = "资料页新昵称"
        storedAccount = try await store.load()
        XCTAssertEqual(storedAccount, expectedAccount)
    }

    func testAccountStoreRejectsPersistedCookieHeaderInjection() async throws {
        var account = Self.makeAccount()
        account.bduss = "safe\r\nX-Injected: true"
        let service = MemoryAccountStoreService(data: try JSONEncoder().encode(account))
        let store = AccountStore(service: service)

        do {
            _ = try await store.load()
            XCTFail("Expected unsafe persisted credentials to be rejected")
        } catch {
            XCTAssertEqual(error as? AccountStoreError, .invalidCredentials)
        }
        let remainingData = try await service.loadData()
        XCTAssertNil(remainingData)
    }

    func testLoginValidationRejectsUnsafeCookieBeforeNetworkRequest() async throws {
        let api = makeAPI { _ in
            XCTFail("Unsafe cookies must be rejected before starting a request")
            return Data()
        }

        do {
            _ = try await api.validateLogin(cookies: BaiduCookies(
                bduss: "bduss; EXTRA=leak",
                stoken: "stoken",
                baiduID: nil
            ))
            XCTFail("Expected unsafe cookie rejection")
        } catch {
            XCTAssertEqual(error as? AuthSessionError, .untrustedCookie)
        }
    }

    func testLegacyAccountMigratesOnlyAfterKeychainWriteAndDeletesPlaintext() async throws {
        let account = Self.makeAccount()
        var legacyJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as? [String: Any]
        )
        legacyJSON["cookie"] = "BDUSS=must-not-survive; STOKEN=must-not-survive"
        legacyJSON["unknown_legacy_field"] = "must-not-survive"
        let data = try JSONSerialization.data(withJSONObject: legacyJSON)
        let keychain = MemoryAccountStoreService()
        let legacy = MemoryAccountStoreService(data: data)
        let service = MigratingAccountStoreService(keychain: keychain, legacyFile: legacy)
        let store = AccountStore(service: service)

        let loadedAccount = try await store.load()
        XCTAssertEqual(loadedAccount, account)
        let storedMigration = try await keychain.loadData()
        let migrated = try XCTUnwrap(storedMigration)
        let plaintext = try await legacy.loadData()
        XCTAssertEqual(try JSONDecoder().decode(Account.self, from: migrated), account)
        let migratedText = try XCTUnwrap(String(data: migrated, encoding: .utf8))
        XCTAssertFalse(migratedText.contains("cookie"))
        XCTAssertFalse(migratedText.contains("unknown_legacy_field"))
        XCTAssertFalse(migratedText.contains("must-not-survive"))
        XCTAssertNil(plaintext)
    }

    func testMigrationFailureDoesNotReturnPlaintextCredentials() async throws {
        let data = try JSONEncoder().encode(Self.makeAccount())
        let legacy = MemoryAccountStoreService(data: data)
        let service = MigratingAccountStoreService(
            keychain: UnavailableAccountStoreService(),
            legacyFile: legacy
        )

        do {
            _ = try await service.loadData()
            XCTFail("Expected migration to fail")
        } catch {
            XCTAssertEqual(error as? AccountMigrationError, .keychainWriteFailed)
        }
        let remaining = try await legacy.loadData()
        XCTAssertNil(remaining)
    }

    func testExistingKeychainAccountIsReencodedToRemoveLegacyCookie() async throws {
        let account = Self.makeAccount()
        var legacyJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as? [String: Any]
        )
        legacyJSON["cookie"] = "BDUSS=old-full-cookie; STOKEN=old-full-cookie"
        let legacyKeychainData = try JSONSerialization.data(withJSONObject: legacyJSON)
        let keychain = MemoryAccountStoreService(data: legacyKeychainData)
        let legacyFile = MemoryAccountStoreService()
        let store = AccountStore(service: MigratingAccountStoreService(
            keychain: keychain,
            legacyFile: legacyFile
        ))

        let loaded = try await store.load()
        XCTAssertEqual(loaded, account)
        let storedData = try await keychain.loadData()
        let sanitized = try XCTUnwrap(storedData)
        let sanitizedText = try XCTUnwrap(String(data: sanitized, encoding: .utf8))
        XCTAssertFalse(sanitizedText.contains("cookie"))
        XCTAssertFalse(sanitizedText.contains("old-full-cookie"))
    }

    func testLegacyFileReaderOnlyLoadsAndClearsData() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "account.json")
        let service = FileAccountStoreService(fileURL: fileURL)
        let data = try JSONEncoder().encode(Self.makeAccount())

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        let loadedData = try await service.loadData()
        XCTAssertEqual(loadedData, data)

        try await service.clearData()
        let clearedData = try await service.loadData()
        XCTAssertNil(clearedData)
    }

    func testAuthSessionExtractsBaiduCookies() throws {
        let cookies = [
            HTTPCookie(properties: [
                .name: "BDUSS",
                .value: "bduss",
                .domain: ".baidu.com",
                .path: "/",
                .secure: "TRUE"
            ])!,
            HTTPCookie(properties: [
                .name: "STOKEN",
                .value: "stoken",
                .domain: ".baidu.com",
                .path: "/",
                .secure: "TRUE"
            ])!,
            HTTPCookie(properties: [
                .name: "BAIDUID",
                .value: "baiduid",
                .domain: ".baidu.com",
                .path: "/",
                .secure: "TRUE"
            ])!
        ]

        let result = try AuthSession.extract(from: cookies)

        XCTAssertEqual(result.bduss, "bduss")
        XCTAssertEqual(result.stoken, "stoken")
        XCTAssertEqual(result.baiduID, "baiduid")
        XCTAssertEqual(result.minimalCookieHeader, "BDUSS=bduss; STOKEN=stoken; BAIDUID=baiduid")
    }

    func testAuthSessionHandlesDuplicateCookieNames() throws {
        let cookies = [
            HTTPCookie(properties: [
                .name: "BDUSS",
                .value: "old-bduss",
                .domain: ".baidu.com",
                .path: "/",
                .secure: "TRUE"
            ])!,
            HTTPCookie(properties: [
                .name: "BDUSS",
                .value: "new-bduss",
                .domain: ".tieba.baidu.com",
                .path: "/",
                .secure: "TRUE"
            ])!,
            HTTPCookie(properties: [
                .name: "STOKEN",
                .value: "stoken",
                .domain: ".baidu.com",
                .path: "/",
                .secure: "TRUE"
            ])!
        ]

        let result = try AuthSession.extract(from: cookies)

        XCTAssertEqual(result.bduss, "new-bduss")
        XCTAssertEqual(result.stoken, "stoken")
    }

    func testAuthSessionPrefersTiebaSTokenWhenDuplicateDomainsExist() throws {
        let cookies = [
            HTTPCookie(properties: [
                .name: "BDUSS",
                .value: "bduss",
                .domain: ".baidu.com",
                .path: "/",
                .secure: "TRUE"
            ])!,
            HTTPCookie(properties: [
                .name: "STOKEN",
                .value: "wappass-stoken",
                .domain: ".wappass.baidu.com",
                .path: "/",
                .secure: "TRUE"
            ])!,
            HTTPCookie(properties: [
                .name: "STOKEN",
                .value: "tieba-stoken",
                .domain: ".tieba.baidu.com",
                .path: "/",
                .secure: "TRUE"
            ])!
        ]

        let result = try AuthSession.extract(from: cookies)

        XCTAssertEqual(result.stoken, "tieba-stoken")
    }

    func testAuthSessionDetectsRequiredCookiesAcrossPassportAndTiebaDomains() throws {
        let cookies = [
            HTTPCookie(properties: [
                .name: "BDUSS",
                .value: "bduss",
                .domain: ".baidu.com",
                .path: "/",
                .secure: "TRUE"
            ])!,
            HTTPCookie(properties: [
                .name: "STOKEN",
                .value: "wappass-stoken",
                .domain: ".wappass.baidu.com",
                .path: "/",
                .secure: "TRUE"
            ])!,
            HTTPCookie(properties: [
                .name: "STOKEN",
                .value: "tieba-stoken",
                .domain: ".tieba.baidu.com",
                .path: "/",
                .secure: "TRUE"
            ])!
        ]

        XCTAssertTrue(AuthSession.hasRequiredCookies(cookies))
    }

    func testAuthSessionRejectsLookalikeDomainInsecureAndExpiredCookies() throws {
        let validBDUSS = Self.cookie(name: "BDUSS", value: "valid", domain: ".baidu.com")
        let attackSToken = Self.cookie(name: "STOKEN", value: "attack", domain: ".tieba.baidu.com.attacker.example")
        XCTAssertFalse(AuthSession.hasRequiredCookies([validBDUSS, attackSToken]))

        let insecureSToken = Self.cookie(name: "STOKEN", value: "insecure", domain: ".baidu.com", secure: false)
        XCTAssertFalse(AuthSession.hasRequiredCookies([validBDUSS, insecureSToken]))

        let expiredBDUSS = Self.cookie(
            name: "BDUSS",
            value: "expired",
            domain: ".baidu.com",
            expires: Date(timeIntervalSinceNow: -60)
        )
        let validSToken = Self.cookie(name: "STOKEN", value: "valid", domain: ".tieba.baidu.com")
        XCTAssertFalse(AuthSession.hasRequiredCookies([expiredBDUSS, validSToken]))
    }

    func testApprovedHTTPSCompletionNormalizesActualIOSBaiduCookieTopology() throws {
        let cookies = [
            Self.cookie(name: "BDUSS", value: "bduss", domain: ".baidu.com", secure: false),
            Self.cookie(name: "STOKEN", value: "stoken", domain: ".wappass.baidu.com"),
            Self.cookie(name: "BAIDUID", value: "baiduid", domain: ".baidu.com", secure: false)
        ]
        XCTAssertFalse(AuthSession.hasRequiredCookies(cookies))

        let normalized = AuthSession.cookiesForApprovedHTTPSCompletion(
            cookies,
            completionURL: AuthSession.loginCompletionURL
        )

        XCTAssertTrue(AuthSession.hasRequiredCookies(normalized))
        XCTAssertTrue(normalized.first(where: { $0.name == "BDUSS" })?.isSecure == true)
        XCTAssertTrue(normalized.first(where: { $0.name == "BAIDUID" })?.isSecure == true)
        let result = try AuthSession.extract(from: normalized)
        XCTAssertEqual(result.bduss, "bduss")
        XCTAssertEqual(result.stoken, "stoken")
        XCTAssertEqual(result.baiduID, "baiduid")
    }

    func testCookieCompatibilityUpgradeRequiresExactHTTPSCompletionURL() throws {
        let insecureBDUSS = Self.cookie(
            name: "BDUSS",
            value: "bduss",
            domain: ".baidu.com",
            secure: false
        )
        let stoken = Self.cookie(name: "STOKEN", value: "stoken", domain: ".wappass.baidu.com")
        let passportURL = try XCTUnwrap(URL(string: "https://wappass.baidu.com/passport"))

        let normalized = AuthSession.cookiesForApprovedHTTPSCompletion(
            [insecureBDUSS, stoken],
            completionURL: passportURL
        )

        XCTAssertFalse(normalized[0].isSecure)
        XCTAssertFalse(AuthSession.hasRequiredCookies(normalized))
    }

    func testCookieCompatibilityUpgradeNeverRelaxesSTokenOrDomainValidation() {
        let secureBDUSS = Self.cookie(name: "BDUSS", value: "bduss", domain: ".baidu.com")
        let insecureSToken = Self.cookie(
            name: "STOKEN",
            value: "stoken",
            domain: ".wappass.baidu.com",
            secure: false
        )
        let attackBDUSS = Self.cookie(
            name: "BDUSS",
            value: "attack",
            domain: ".baidu.com.attacker.example",
            secure: false
        )
        let secureSToken = Self.cookie(name: "STOKEN", value: "stoken", domain: ".wappass.baidu.com")

        let insecureSTokenResult = AuthSession.cookiesForApprovedHTTPSCompletion(
            [secureBDUSS, insecureSToken],
            completionURL: AuthSession.loginCompletionURL
        )
        XCTAssertFalse(AuthSession.hasRequiredCookies(insecureSTokenResult))

        let attackDomainResult = AuthSession.cookiesForApprovedHTTPSCompletion(
            [attackBDUSS, secureSToken],
            completionURL: AuthSession.loginCompletionURL
        )
        XCTAssertFalse(attackDomainResult[0].isSecure)
        XCTAssertFalse(AuthSession.hasRequiredCookies(attackDomainResult))
    }

    func testAuthSessionMinimalHeaderExcludesUnrelatedBrowserCookies() throws {
        let cookies = [
            Self.cookie(name: "BDUSS", value: "bduss", domain: ".baidu.com"),
            Self.cookie(name: "STOKEN", value: "stoken", domain: ".tieba.baidu.com"),
            Self.cookie(name: "SESSION", value: "must-not-leak", domain: ".baidu.com")
        ]

        let result = try AuthSession.extract(from: cookies)
        XCTAssertEqual(result.minimalCookieHeader, "BDUSS=bduss; STOKEN=stoken")
        XCTAssertFalse(result.minimalCookieHeader.contains("SESSION"))
    }

    func testAuthSessionRecognizesTiebaSuccessURL() throws {
        let url = try XCTUnwrap(URL(string: "https://tieba.baidu.com/index/tbwise/mine"))

        XCTAssertTrue(AuthSession.isSuccessURL(url))
        XCTAssertTrue(AuthSession.shouldCaptureCompletionWithoutRendering(url))
        XCTAssertEqual(AuthSession.loginCompletionURL, url)
    }

    func testOnlyExactCompletionURLIsCapturedWithoutRendering() throws {
        let completion = try XCTUnwrap(URL(string: "https://tieba.baidu.com/index/tbwise/mine"))
        let ordinaryTiebaPage = try XCTUnwrap(URL(string: "https://tieba.baidu.com/f?kw=swift"))
        let lookalike = try XCTUnwrap(URL(string: "https://tieba.baidu.com.attacker.example/index/tbwise/mine"))

        XCTAssertTrue(AuthSession.shouldCaptureCompletionWithoutRendering(completion))
        XCTAssertFalse(AuthSession.shouldCaptureCompletionWithoutRendering(ordinaryTiebaPage))
        XCTAssertFalse(AuthSession.shouldCaptureCompletionWithoutRendering(lookalike))
    }

    func testLoginNavigationRequiresHTTPSBaiduBoundaryWithoutUserInfo() throws {
        XCTAssertTrue(AuthSession.isAllowedLoginURL(try XCTUnwrap(URL(string: "https://wappass.baidu.com/passport"))))
        XCTAssertFalse(AuthSession.isAllowedLoginURL(try XCTUnwrap(URL(string: "http://wappass.baidu.com/passport"))))
        XCTAssertFalse(AuthSession.isAllowedLoginURL(try XCTUnwrap(URL(string: "https://baidu.com.attacker.example/"))))
        XCTAssertFalse(AuthSession.isAllowedLoginURL(try XCTUnwrap(URL(string: "https://user@tieba.baidu.com/"))))
        XCTAssertFalse(AuthSession.isAllowedLoginURL(try XCTUnwrap(URL(string: "https://tieba.baidu.com:8443/"))))
        XCTAssertTrue(AuthSession.isAllowedLoginURL(try XCTUnwrap(URL(string: "https://tieba.baidu.com:443/"))))
        XCTAssertFalse(AuthSession.isSuccessURL(try XCTUnwrap(URL(string: "https://tieba.baidu.com:8443/index/tbwise/mine"))))
        XCTAssertFalse(AuthSession.isSuccessURL(try XCTUnwrap(URL(string: "https://tieba.baidu.com/index/tbwise/mine/extra"))))
    }

    func testAuthSessionAllowsCookieValidationOnTiebaWebPages() throws {
        let tiebaMine = try XCTUnwrap(URL(string: "https://tieba.baidu.com/mo/q/newmoindex?need_user=1"))
        let successURL = try XCTUnwrap(URL(string: "https://tieba.baidu.com/index/tbwise/mine"))
        let passportURL = try XCTUnwrap(URL(string: "https://wappass.baidu.com/passport?login"))

        XCTAssertFalse(AuthSession.shouldAttemptCookieValidation(on: tiebaMine))
        XCTAssertTrue(AuthSession.shouldAttemptCookieValidation(on: successURL))
        XCTAssertFalse(AuthSession.shouldAttemptCookieValidation(on: passportURL))
    }

    func testAuthSessionCancelsExternalAppRedirects() throws {
        let customScheme = try XCTUnwrap(URL(string: "tbclient://jump/pb?tid=1"))
        let encodedScheme = try XCTUnwrap(URL(string: "https://tieba.baidu.com/mo/q/checkurl?schema=tbclient%3A%2F%2Fjump%2Fpb%3Ftid%3D1"))
        let appStore = try XCTUnwrap(URL(string: "https://apps.apple.com/cn/app/id477927812"))
        let appDistributor = try XCTUnwrap(URL(
            string: "https://a.app.qq.com/o/simple.jsp?pkgname=com.baidu.tieba"
        ))
        let webURL = try XCTUnwrap(URL(string: "https://wappass.baidu.com/passport?login"))

        XCTAssertTrue(AuthSession.isExternalAppRedirectURL(customScheme))
        XCTAssertTrue(AuthSession.isExternalAppRedirectURL(encodedScheme))
        XCTAssertTrue(AuthSession.isExternalAppRedirectURL(appStore))
        XCTAssertTrue(AuthSession.isExternalAppRedirectURL(appDistributor))
        XCTAssertFalse(AuthSession.isExternalAppRedirectURL(webURL))
    }

    func testLoginNavigationAllowsOnlyInertAboutBlankDocument() throws {
        XCTAssertTrue(AuthSession.isInertLoginDocumentURL(try XCTUnwrap(URL(string: "about:blank"))))
        XCTAssertFalse(AuthSession.isInertLoginDocumentURL(try XCTUnwrap(URL(string: "about:srcdoc"))))
        XCTAssertFalse(AuthSession.isInertLoginDocumentURL(try XCTUnwrap(URL(string: "javascript:alert(1)"))))
    }

    func testPostLoginAppRedirectRecoversOnTrustedTiebaWebPage() throws {
        let appRedirect = try XCTUnwrap(URL(
            string: "https://tieba.baidu.com/mo/q/checkurl?schema=tbclient%3A%2F%2Fjump%2Fpb"
        ))
        let universalLink = try XCTUnwrap(URL(string: "https://a.app.qq.com/o/simple.jsp?pkgname=com.baidu.tieba"))

        XCTAssertEqual(
            AuthSession.blockedNavigationResolution(
                for: appRedirect,
                hasPrimaryLoginCookie: true,
                isUserInitiated: true
            ),
            .recoverOnTiebaWeb
        )
        XCTAssertEqual(
            AuthSession.blockedNavigationResolution(
                for: universalLink,
                hasPrimaryLoginCookie: true,
                isUserInitiated: true
            ),
            .recoverOnTiebaWeb
        )
        XCTAssertEqual(
            AuthSession.blockedNavigationResolution(
                for: appRedirect,
                hasPrimaryLoginCookie: false,
                isUserInitiated: true
            ),
            .ignore
        )
    }

    func testAutomaticBlockedRedirectDoesNotShowSpuriousLoginFailure() throws {
        let insecureRedirect = try XCTUnwrap(URL(string: "http://wappass.baidu.com/passport"))
        XCTAssertEqual(
            AuthSession.blockedNavigationResolution(
                for: insecureRedirect,
                hasPrimaryLoginCookie: false,
                isUserInitiated: false
            ),
            .ignore
        )
        XCTAssertEqual(
            AuthSession.blockedNavigationResolution(
                for: insecureRedirect,
                hasPrimaryLoginCookie: false,
                isUserInitiated: true
            ),
            .reportError
        )
    }

    func testPrimaryLoginCookieRequiresTrustedSecureBaiduCookie() {
        XCTAssertTrue(AuthSession.hasPrimaryLoginCookie([
            Self.cookie(name: "BDUSS", value: "valid", domain: ".baidu.com")
        ]))
        XCTAssertFalse(AuthSession.hasPrimaryLoginCookie([
            Self.cookie(name: "BDUSS", value: "insecure", domain: ".baidu.com", secure: false)
        ]))
        XCTAssertFalse(AuthSession.hasPrimaryLoginCookie([
            Self.cookie(name: "BDUSS", value: "attack", domain: ".baidu.com.attacker.example")
        ]))
    }

    func testValidateLoginFallsBackToWebMyInfoWhenClientLoginHasNoUser() async throws {
        let api = makeAPI { request in
            let url = try XCTUnwrap(request.url)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

            switch components.path {
            case "/c/s/login":
                XCTAssertEqual(request.httpMethod, "POST")
                return Self.clientLoginRejectedJSON
            case "/c/s/initNickname":
                XCTAssertEqual(request.httpMethod, "POST")
                return Self.clientLoginRejectedJSON
            case "/mo/q/newmoindex":
                let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(query["need_user"], "1")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "BDUSS=bduss; STOKEN=stoken; BAIDUID=baiduid")
                return Self.webMyInfoJSON
            default:
                XCTFail("Unexpected request path: \(components.path)")
                return Data()
            }
        }

        let account = try await api.validateLogin(
            cookies: BaiduCookies(
                bduss: "bduss",
                stoken: "stoken",
                baiduID: "baiduid"
            )
        )

        XCTAssertEqual(account.uid, "10001")
        XCTAssertEqual(account.name, "raw_name")
        XCTAssertEqual(account.displayName, "显示昵称")
        XCTAssertEqual(account.portrait, "tb.1.avatar")
        XCTAssertEqual(account.tbs, "web-tbs")
        XCTAssertEqual(account.minimalCookieHeader, "BDUSS=bduss; STOKEN=stoken; BAIDUID=baiduid")
    }

    func testLoginResponseDecodesNumericErrorCodeAndUserFields() throws {
        let json = Data("""
        {
          "error_code": 110001,
          "error_msg": "未知错误",
          "user": {"id": 42, "name": "raw", "portrait": "tb.1.demo"},
          "anti": {"tbs": 12345}
        }
        """.utf8)

        let response = try JSONDecoder().decode(LoginResponseDTO.self, from: json)

        XCTAssertEqual(response.errorCode, "110001")
        XCTAssertEqual(response.errorMessage, "未知错误")
        XCTAssertEqual(response.user?.id, "42")
        XCTAssertEqual(response.user?.name, "raw")
        XCTAssertEqual(response.anti?.tbs, "12345")
    }

    func testFreshInstallCleanupClearsLeftoverCredentialOnceAndWritesSentinel() throws {
        let (defaults, suiteName) = try Self.makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let install = Date()
        var clearCount = 0
        let cleanup = FreshInstallCredentialCleanup(
            defaults: defaults,
            storedCredentialCreationState: { .found(install.addingTimeInterval(-86_400)) },
            sandboxCreationDate: { install }
        ) {
            clearCount += 1
        }

        XCTAssertEqual(cleanup.runIfNeeded(), .completed)

        XCTAssertEqual(clearCount, 1)
        XCTAssertNotNil(defaults.object(forKey: FreshInstallCredentialCleanup.sentinelKey))

        XCTAssertEqual(cleanup.runIfNeeded(), .completed)
        XCTAssertEqual(clearCount, 1)
    }

    func testUpgradeInstallKeepsCredentialSavedByCurrentInstall() throws {
        let (defaults, suiteName) = try Self.makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let install = Date()
        var clearCount = 0
        // Upgrade path: the credential was written after this sandbox was
        // created, so it belongs to the current install and must survive.
        let cleanup = FreshInstallCredentialCleanup(
            defaults: defaults,
            storedCredentialCreationState: { .found(install.addingTimeInterval(3_600)) },
            sandboxCreationDate: { install }
        ) {
            clearCount += 1
        }

        XCTAssertEqual(cleanup.runIfNeeded(), .completed)

        XCTAssertEqual(clearCount, 0)
        XCTAssertNotNil(defaults.object(forKey: FreshInstallCredentialCleanup.sentinelKey))
    }

    func testFreshInstallCleanupCompletesWhenKeychainConfirmsNoCredential() throws {
        let (defaults, suiteName) = try Self.makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var clearCount = 0
        let cleanup = FreshInstallCredentialCleanup(
            defaults: defaults,
            storedCredentialCreationState: { .notFound },
            sandboxCreationDate: {
                XCTFail("A missing credential does not require sandbox metadata")
                throw KeychainError.status(errSecParam)
            }
        ) {
            clearCount += 1
        }

        XCTAssertEqual(cleanup.runIfNeeded(), .completed)

        XCTAssertEqual(clearCount, 0)
        XCTAssertNotNil(defaults.object(forKey: FreshInstallCredentialCleanup.sentinelKey))
    }

    func testFreshInstallCleanupRetriesAfterKeychainQueryFailure() throws {
        let (defaults, suiteName) = try Self.makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var shouldFail = true
        let cleanup = FreshInstallCredentialCleanup(
            defaults: defaults,
            storedCredentialCreationState: {
                if shouldFail { throw KeychainError.status(errSecInteractionNotAllowed) }
                return .notFound
            },
            sandboxCreationDate: { Date() },
            clearStoredCredentials: {}
        )

        XCTAssertEqual(cleanup.runIfNeeded(), .deferred)
        XCTAssertNil(defaults.object(forKey: FreshInstallCredentialCleanup.sentinelKey))

        shouldFail = false
        XCTAssertEqual(cleanup.runIfNeeded(), .completed)
        XCTAssertNotNil(defaults.object(forKey: FreshInstallCredentialCleanup.sentinelKey))
    }

    func testFreshInstallCleanupRetriesAfterSandboxDateFailure() throws {
        let (defaults, suiteName) = try Self.makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let install = Date()
        var shouldFail = true
        var clearCount = 0
        let cleanup = FreshInstallCredentialCleanup(
            defaults: defaults,
            storedCredentialCreationState: { .found(install.addingTimeInterval(-86_400)) },
            sandboxCreationDate: {
                if shouldFail { throw CocoaError(.fileReadUnknown) }
                return install
            }
        ) {
            clearCount += 1
        }

        XCTAssertEqual(cleanup.runIfNeeded(), .deferred)
        XCTAssertEqual(clearCount, 0)
        XCTAssertNil(defaults.object(forKey: FreshInstallCredentialCleanup.sentinelKey))

        shouldFail = false
        XCTAssertEqual(cleanup.runIfNeeded(), .completed)
        XCTAssertEqual(clearCount, 1)
        XCTAssertNotNil(defaults.object(forKey: FreshInstallCredentialCleanup.sentinelKey))
    }

    func testKeychainCreationStateDistinguishesMissingPresentAndQueryFailure() throws {
        let creationDate = Date(timeIntervalSince1970: 1_700_000_000)
        let missing = KeychainCreationStateOperations(status: errSecItemNotFound)
        XCTAssertEqual(
            try KeychainAccountStoreService(securityOperations: missing).storedItemCreationState(),
            .notFound
        )

        let present = KeychainCreationStateOperations(
            status: errSecSuccess,
            attributes: [kSecAttrCreationDate as String: creationDate]
        )
        XCTAssertEqual(
            try KeychainAccountStoreService(securityOperations: present).storedItemCreationState(),
            .found(creationDate)
        )

        let failed = KeychainCreationStateOperations(status: errSecInteractionNotAllowed)
        XCTAssertThrowsError(
            try KeychainAccountStoreService(securityOperations: failed).storedItemCreationState()
        ) { error in
            XCTAssertEqual(error as? KeychainError, .status(errSecInteractionNotAllowed))
        }

        let malformed = KeychainCreationStateOperations(status: errSecSuccess, attributes: [:])
        XCTAssertThrowsError(
            try KeychainAccountStoreService(securityOperations: malformed).storedItemCreationState()
        ) { error in
            XCTAssertEqual(error as? KeychainError, .invalidItemAttributes)
        }
    }

    func testFreshInstallCleanupRetriesWhenClearingFails() throws {
        let (defaults, suiteName) = try Self.makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let install = Date()
        var shouldFail = true
        var clearCount = 0
        let cleanup = FreshInstallCredentialCleanup(
            defaults: defaults,
            storedCredentialCreationState: { .found(install.addingTimeInterval(-86_400)) },
            sandboxCreationDate: { install }
        ) {
            clearCount += 1
            if shouldFail { throw KeychainError.status(-1) }
        }

        XCTAssertEqual(cleanup.runIfNeeded(), .deferred)
        XCTAssertEqual(clearCount, 1)
        XCTAssertNil(defaults.object(forKey: FreshInstallCredentialCleanup.sentinelKey))

        shouldFail = false
        XCTAssertEqual(cleanup.runIfNeeded(), .completed)
        XCTAssertEqual(clearCount, 2)
        XCTAssertNotNil(defaults.object(forKey: FreshInstallCredentialCleanup.sentinelKey))
    }

    func testDeferredFreshInstallStoreDoesNotExposeOrDeleteOldCredential() async throws {
        let oldData = try JSONEncoder().encode(Self.makeAccount())
        let keychain = RecordingAccountStoreService(data: oldData)
        let service = DeferredFreshInstallAccountStoreService(
            keychain: keychain,
            markCleanupCompleted: {}
        )

        let gatedData = try await service.loadData()
        XCTAssertNil(gatedData)
        try await service.clearData()

        let untouchedState = await keychain.state()
        XCTAssertEqual(untouchedState.data, oldData)
        XCTAssertEqual(untouchedState.loadCount, 0)
        XCTAssertEqual(untouchedState.clearCount, 0)
    }

    func testDeferredFreshInstallStoreAllowsNewLoginWithoutReadingOldCredential() async throws {
        let (defaults, suiteName) = try Self.makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let oldData = try JSONEncoder().encode(Self.makeAccount())
        let keychain = RecordingAccountStoreService(data: oldData)
        let store = AccountStore(
            service: DeferredFreshInstallAccountStoreService(
                keychain: keychain,
                markCleanupCompleted: {
                    guard let markerDefaults = UserDefaults(suiteName: suiteName) else {
                        throw CocoaError(.coderInvalidValue)
                    }
                    FreshInstallCredentialCleanup.markCompleted(in: markerDefaults)
                }
            )
        )
        var replacement = Self.makeAccount()
        replacement.uid = "84"
        replacement.name = "replacement"
        replacement.displayName = "新登录"
        replacement.bduss = "new-bduss"
        replacement.stoken = "new-stoken"
        replacement.baiduID = "new-baiduid"
        replacement.tbs = "new-tbs"

        let accountBeforeReplacement = try await store.load()
        XCTAssertNil(accountBeforeReplacement)
        try await store.save(replacement)
        let accountAfterReplacement = try await store.load()
        XCTAssertEqual(accountAfterReplacement, replacement)

        let state = await keychain.state()
        XCTAssertEqual(state.loadCount, 1)
        XCTAssertEqual(state.saveCount, 1)
        XCTAssertEqual(try JSONDecoder().decode(Account.self, from: XCTUnwrap(state.data)), replacement)
        XCTAssertNotNil(defaults.object(forKey: FreshInstallCredentialCleanup.sentinelKey))
    }

    func testDeferredFreshInstallStoreStaysClosedWhenCompletionMarkerFails() async throws {
        let oldData = try JSONEncoder().encode(Self.makeAccount())
        let replacementData = Data("replacement".utf8)
        let keychain = RecordingAccountStoreService(data: oldData)
        let service = DeferredFreshInstallAccountStoreService(
            keychain: keychain,
            markCleanupCompleted: {
                throw UnavailableAccountStoreError.unavailable
            }
        )

        do {
            try await service.saveData(replacementData)
            XCTFail("A failed completion marker must fail the replacement")
        } catch {
            XCTAssertTrue(error is UnavailableAccountStoreError)
        }
        let gatedData = try await service.loadData()
        XCTAssertNil(gatedData)

        let state = await keychain.state()
        XCTAssertEqual(state.data, replacementData)
        XCTAssertEqual(state.loadCount, 0)
        XCTAssertEqual(state.saveCount, 1)
        XCTAssertEqual(state.clearCount, 0)
    }

    func testWebFallbackPrefersClientTBSOverWebTBS() async throws {
        let api = makeAPI { request in
            let path = try XCTUnwrap(request.url?.path)
            switch path {
            case "/c/s/login":
                // 登录也走 protobuf 主机那条即时返回的路由，不再用应用主机的
                // 同步长连接（真机实测每次 20.1 秒）。
                XCTAssertEqual(request.url?.host, "tiebac.baidu.com")
                return Data(#"{"error_code":"0","anti":{"tbs":"client-tbs"}}"#.utf8)
            case "/c/s/initNickname":
                return Data("{}".utf8)
            case "/mo/q/newmoindex":
                return Self.webMyInfoJSON
            default:
                XCTFail("Unexpected request path: \(path)")
                return Data()
            }
        }

        let account = try await api.validateLogin(
            cookies: BaiduCookies(bduss: "bduss", stoken: "stoken", baiduID: "baiduid")
        )

        XCTAssertEqual(account.tbs, "client-tbs")
    }

    private func makeAPI(handler: @escaping (URLRequest) throws -> Data) -> TiebaAPI {
        AuthMockURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return TiebaAPI(client: TiebaHTTPClient(session: session))
    }

    private static func makeIsolatedDefaults() throws -> (UserDefaults, String) {
        let suiteName = "dev.infinityf4p.tiebapure.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    private static func makeAccount() -> Account {
        Account(
            uid: "42",
            name: "raw",
            displayName: "Raw",
            portrait: "portrait",
            bduss: "bduss",
            stoken: "stoken",
            baiduID: "baiduid",
            tbs: "tbs"
        )
    }

    private static func cookie(
        name: String,
        value: String,
        domain: String,
        secure: Bool = true,
        expires: Date? = nil
    ) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: "/"
        ]
        if secure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }

    private static let clientLoginRejectedJSON = """
    {
      "error_code": "110001",
      "error_msg": "未知错误",
      "info": [],
      "ctime": 1710000000,
      "logid": 1,
      "server_time": "1710000000",
      "time": 1710000000
    }
    """.data(using: .utf8)!

    private static let webMyInfoJSON = """
    {
      "no": 0,
      "error": "success",
      "data": {
        "is_login": true,
        "uid": 10001,
        "name": "raw_name",
        "name_show": "显示昵称",
        "portrait": "tb.1.avatar",
        "portrait_url": "https://tb.himg.baidu.com/sys/portrait/item/tb.1.avatar",
        "tbs": "web-tbs",
        "itb_tbs": "web-itb-tbs"
      }
    }
    """.data(using: .utf8)!
}

private final class AuthMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> Data)?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let data = try XCTUnwrap(Self.handler)(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private actor UnavailableAccountStoreService: AccountStoreService {
    func loadData() async throws -> Data? {
        throw UnavailableAccountStoreError.unavailable
    }

    func saveData(_ data: Data) async throws {
        throw UnavailableAccountStoreError.unavailable
    }

    func clearData() async throws {
        throw UnavailableAccountStoreError.unavailable
    }
}

private enum UnavailableAccountStoreError: Error {
    case unavailable
}

private actor RecordingAccountStoreService: AccountStoreService {
    struct State: Sendable {
        var data: Data?
        var loadCount: Int
        var saveCount: Int
        var clearCount: Int
    }

    private var data: Data?
    private var loadCount = 0
    private var saveCount = 0
    private var clearCount = 0

    init(data: Data? = nil) {
        self.data = data
    }

    func loadData() async throws -> Data? {
        loadCount += 1
        return data
    }

    func saveData(_ data: Data) async throws {
        saveCount += 1
        self.data = data
    }

    func clearData() async throws {
        clearCount += 1
        data = nil
    }

    func state() -> State {
        State(
            data: data,
            loadCount: loadCount,
            saveCount: saveCount,
            clearCount: clearCount
        )
    }
}

private final class KeychainCreationStateOperations: KeychainSecurityOperating, @unchecked Sendable {
    private let status: OSStatus
    private let attributes: [String: Any]?

    init(status: OSStatus, attributes: [String: Any]? = nil) {
        self.status = status
        self.attributes = attributes
    }

    func copyMatching(
        _ query: CFDictionary,
        result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        if let attributes {
            result?.pointee = attributes as CFDictionary
        }
        return status
    }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus { errSecUnimplemented }
    func add(_ attributes: CFDictionary) -> OSStatus { errSecUnimplemented }
    func delete(_ query: CFDictionary) -> OSStatus { errSecUnimplemented }
}
