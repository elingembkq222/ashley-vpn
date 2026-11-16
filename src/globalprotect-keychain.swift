import CryptoKit
import Darwin
import Foundation
import Security

// The issuer must be verified by the trust evaluation, not by its display name.
private let companyCA = "a3e586bf8b8fe284b7a825929d00ee242eec26f94fc4347380ecb53e621eff38"
// Imported private keys use this rule for the application list shown in Keychain Access.
private let privateKeyActions = Set([
    kSecACLAuthorizationDecrypt, kSecACLAuthorizationDerive, kSecACLAuthorizationExportClear,
    kSecACLAuthorizationExportWrapped, kSecACLAuthorizationMAC, kSecACLAuthorizationSign,
].map { $0 as String })
private let components = [
    ("/Applications/GlobalProtect.app", "com.paloaltonetworks.GlobalProtect.client"),
    ("/Applications/GlobalProtect.app/Contents/Resources/PanGPS", "PanGPS"),
]

private typealias SigningApplication = (path: String, trusted: SecTrustedApplication)
private typealias ValidateTrustedApplication = @convention(c) (SecTrustedApplication, UnsafePointer<CChar>) -> OSStatus

// The legacy Keychain API's CopyData returns only a path, not the stored code requirement.
// Use the Security framework's verifier when available so a stale grant does not pass the check.
// Swift does not import Darwin's pointer-valued RTLD_DEFAULT macro (-2).
private let validateTrustedApplication = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                               "SecTrustedApplicationValidateWithPath").map {
    unsafeBitCast($0, to: ValidateTrustedApplication.self)
}

private func fingerprint(_ certificate: SecCertificate) -> String {
    SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
        .map { String(format: "%02x", $0) }.joined()
}

private func isCompanyClientCertificate(_ certificate: SecCertificate) -> Bool {
    var result: SecTrust?
    guard SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(false, nil), &result) == errSecSuccess,
          let trust = result,
          SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
          SecTrustEvaluateWithError(trust, nil),
          let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
          chain.count > 1, fingerprint(chain[1]) == companyCA else { return false }

    // Match the device certificate usages observed on both GlobalProtect installations.
    let eku = "2.5.29.37"
    guard let fields = SecCertificateCopyValues(certificate, [eku] as CFArray, nil)
            as? [String: [String: Any]],
          let usages = fields[eku]?[kSecPropertyKeyValue as String] as? [Data]
    else { return false }
    let profile = Set([0x01, 0x02, 0x05].map { Data([0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, $0]) })
    return Set(usages) == profile
}

private func trustedApplication(_ path: String, identifier: String) -> SecTrustedApplication? {
    var code: SecStaticCode?
    var requirement: SecRequirement?
    let expression = "anchor apple generic and certificate leaf[subject.OU] = PXPZ95SK77 and identifier \"\(identifier)\""
    guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
          SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
          let code, let requirement,
          SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
    else { return nil }
    var trusted: SecTrustedApplication?
    guard SecTrustedApplicationCreateFromPath(path, &trusted) == errSecSuccess else { return nil }
    return trusted
}

private func trustedData(_ app: SecTrustedApplication) -> Data? {
    var data: CFData?
    guard SecTrustedApplicationCopyData(app, &data) == errSecSuccess else { return nil }
    return data as Data?
}

private struct PrivateKeyRule {
    let acl: SecACL
    let description: CFString
    let prompt: SecKeychainPromptSelector
    let applications: [SecTrustedApplication]

    init?(_ access: SecAccess) {
        var list: CFArray?
        guard SecAccessCopyACLList(access, &list) == errSecSuccess, let acls = list as? [SecACL] else {
            return nil
        }
        let candidates = acls.filter { Set(SecACLCopyAuthorizations($0) as? [String] ?? []) == privateKeyActions }
        guard candidates.count == 1, let acl = candidates.first else { return nil }

        var applicationList: CFArray?
        var description: CFString?
        var prompt = SecKeychainPromptSelector()
        guard SecACLCopyContents(acl, &applicationList, &description, &prompt) == errSecSuccess,
              let description, let applications = applicationList as? [SecTrustedApplication] else {
            return nil
        }
        self.acl = acl
        self.description = description
        self.prompt = prompt
        self.applications = applications
    }

    func missingApplications(_ expected: [SigningApplication]) -> [SigningApplication]? {
        guard let validateTrustedApplication else { return nil }
        return expected.filter { app in
            let path = Data(app.path.utf8) + Data([0])
            return !applications.contains { stored in
                trustedData(stored) == path &&
                    app.path.withCString { validateTrustedApplication(stored, $0) == errSecSuccess }
            }
        }
    }

    func add(_ missing: [SigningApplication]) -> Bool {
        let paths = Set(missing.map { Data($0.path.utf8) + Data([0]) })
        // Replace obsolete entries for these same paths. Preserve the existing app group,
        // authorization operations, and prompt behavior of the imported private key.
        let retained = applications.filter { app in
            guard let path = trustedData(app) else { return true }
            return !paths.contains(path)
        }
        let updated = retained + missing.map(\.trusted)
        return SecACLSetContents(acl, updated as CFArray, description, prompt) == errSecSuccess
    }

    func restorePrompt() -> Bool {
        SecACLSetContents(acl, applications as CFArray, description, []) == errSecSuccess
    }
}

@discardableResult
private func report(_ message: String, status: Int32 = 0) -> Int32 {
    print(message)
    return status
}

private func checkGlobalProtectSigning(repairFingerprint: String?, restorePrompt: Bool) -> Int32 {
    let apps: [SigningApplication] = components.compactMap { path, identifier in
        trustedApplication(path, identifier: identifier).map { (path, $0) }
    }
    guard apps.count == components.count else {
        return report("无法验证 GlobalProtect 或 PanGPS 的厂商签名，跳过证书权限检查。", status: 1)
    }
    var system: SecKeychain?
    guard SecKeychainOpen("/Library/Keychains/System.keychain", &system) == errSecSuccess,
          let system else { return report("无法读取系统钥匙串。", status: 1) }
    // The check must remain quiet when the user needs no repair.
    guard SecKeychainSetUserInteractionAllowed(repairFingerprint != nil) == errSecSuccess else {
        return report("无法配置钥匙串访问，跳过证书权限检查。", status: 1)
    }
    let query = [
        kSecClass as String: kSecClassIdentity,
        kSecMatchSearchList as String: [system],
        kSecMatchLimit as String: kSecMatchLimitAll,
        kSecReturnRef as String: true,
    ] as CFDictionary
    var result: CFTypeRef?
    let queryStatus = SecItemCopyMatching(query, &result)
    if queryStatus == errSecItemNotFound { return report("系统钥匙串无集团 VPN 客户端证书，跳过权限修复。") }
    guard queryStatus == errSecSuccess, let identities = result as? [SecIdentity] else {
        return report("无法读取系统钥匙串中的客户端证书（\(queryStatus)）。", status: 1)
    }
    let matches = identities.compactMap { identity -> (SecIdentity, SecCertificate)? in
        var result: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &result) == errSecSuccess, let certificate = result,
              isCompanyClientCertificate(certificate) else { return nil }
        return (identity, certificate)
    }
    guard matches.count == 1, let (identity, certificate) = matches.first else {
        return report("无法唯一定位集团 VPN 客户端证书，保留钥匙串原有权限。")
    }
    let expected = fingerprint(certificate)
    if let repairFingerprint, repairFingerprint != expected {
        return report("集团 VPN 证书已变化，请重新检查后再授权。", status: 1)
    }

    var key: SecKey?
    guard SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let key else {
        return report("无法读取集团 VPN 私钥的访问权限。", status: 1)
    }
    // For a file-based keychain the SecKey is also a legacy keychain item.
    let item = unsafeBitCast(key, to: SecKeychainItem.self)
    var resultAccess: SecAccess?
    guard SecKeychainItemCopyAccess(item, &resultAccess) == errSecSuccess,
          let access = resultAccess, let rule = PrivateKeyRule(access),
          let missing = rule.missingApplications(apps) else {
        return report("无法唯一识别集团 VPN 私钥的应用访问规则，未修改钥匙串。", status: 4)
    }
    if restorePrompt {
        if !rule.prompt.contains(.requirePassphase) {
            return report("集团 VPN 私钥未开启逐次密码提示。")
        }
        let expectedPaths = Set((apps.map(\.path) + ["group://com.apple.identity.export"]).map {
            Data($0.utf8) + Data([0])
        })
        let existingPaths = rule.applications.compactMap(trustedData)
        guard rule.prompt == .requirePassphase, missing.isEmpty,
              existingPaths.count == rule.applications.count,
              existingPaths.count == expectedPaths.count, Set(existingPaths) == expectedPaths else {
            return report("集团 VPN 私钥的设置与已知问题不匹配，未修改钥匙串。", status: 4)
        }
    } else if rule.prompt.contains(.requirePassphase) {
        return report("集团 VPN 私钥要求每次访问时验证钥匙串密码，已保留此设置。", status: 4)
    } else if missing.isEmpty {
        return report("集团 VPN 私钥访问权限已齐全。")
    }
    let missingNames = missing.map { URL(fileURLWithPath: $0.path).lastPathComponent }.joined(separator: "、")
    guard repairFingerprint != nil else {
        let message = restorePrompt ? "检测到集团 VPN 私钥已开启逐次密码提示。" : "缺少私钥访问权限：\(missingNames)"
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return report(expected, status: 3)
    }

    let expectedPrompt = restorePrompt ? SecKeychainPromptSelector() : rule.prompt
    guard (restorePrompt ? rule.restorePrompt() : rule.add(missing)) else {
        return report("无法准备集团 VPN 私钥的访问权限。", status: 1)
    }
    let save = SecKeychainItemSetAccess(item, access)
    guard save == errSecSuccess else {
        return report("macOS 未能保存私钥访问权限（\(save)）。", status: 1)
    }
    var verifiedAccess: SecAccess?
    guard SecKeychainItemCopyAccess(item, &verifiedAccess) == errSecSuccess, let verifiedAccess,
          let verifiedRule = PrivateKeyRule(verifiedAccess),
          verifiedRule.prompt == expectedPrompt,
          !restorePrompt || verifiedRule.applications.compactMap(trustedData) == rule.applications.compactMap(trustedData),
          verifiedRule.missingApplications(apps)?.isEmpty == true else {
        return report("无法验证新的签名授权，请在钥匙串访问中检查。", status: 1)
    }
    if restorePrompt {
        return report("已撤销这把集团 VPN 私钥的逐次密码提示，原有应用访问列表已保留。")
    }
    return report("已补齐集团 VPN 私钥访问权限：\(missingNames)。")
}

let args = CommandLine.arguments
if args.count == 2 && ["--check", "--check-prompt"].contains(args[1]) {
    exit(checkGlobalProtectSigning(repairFingerprint: nil, restorePrompt: args[1] == "--check-prompt"))
}
if args.count == 3 && ["--repair", "--restore-prompt"].contains(args[1]),
   args[2].range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil {
    exit(checkGlobalProtectSigning(repairFingerprint: args[2], restorePrompt: args[1] == "--restore-prompt"))
}
exit(2)
