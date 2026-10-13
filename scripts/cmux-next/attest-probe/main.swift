// cmux attest probe (cx-ds09i slice 0). Not a product: it measures whether a
// Developer ID signed Mac app can use App Attest and DeviceCheck.
//
//   attestprobe attest <out-dir>          isSupported, generateKey, attestKey, DCDevice token
//   attestprobe assert <key-id> <out-dir> generateAssertion with an earlier key (reinstall check)
//   attestprobe reattest <out-dir>        generateKey, then attestKey twice on the same key (one process)
//   attestprobe attestkey <key-id> <out-dir> attestKey again on an earlier key (a later launch)
//   attestprobe freeflow <api-origin> <out-dir> the free tier's server checks with real proofs:
//             a forged attestation, a fresh key, a replayed assertion, one more new key
//             (statuses and error codes only; no token, proof or device token is written)
//
// Every result is one JSON object on stdout. The attestation object, the
// assertion and the DeviceCheck token go to files in <out-dir> (mode 0600),
// never to stdout, so a log never holds them.
import CryptoKit
import DeviceCheck
import Foundation

func emit(_ object: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func save(_ data: Data, _ dir: URL, _ name: String) throws {
    let url = dir.appendingPathComponent(name)
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

func describe(_ error: Error) -> [String: Any] {
    let ns = error as NSError
    return ["domain": ns.domain, "code": ns.code, "message": ns.localizedDescription]
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    emit(["error": "usage: attestprobe attest <out-dir> | assert <key-id> <out-dir>"])
    exit(2)
}

var result: [String: Any] = [
    "bundle_id": Bundle.main.bundleIdentifier ?? NSNull(),
    "os": ProcessInfo.processInfo.operatingSystemVersionString,
    "app_attest_supported": DCAppAttestService.shared.isSupported,
    "devicecheck_supported": DCDevice.current.isSupported,
    // How the probe started: "open" (LaunchServices, GUI session) or "direct" (exec, e.g. over SSH).
    "launch": ProcessInfo.processInfo.environment["ATTEST_PROBE_LAUNCH"] ?? "direct",
    "ssh_session": ProcessInfo.processInfo.environment["SSH_CONNECTION"] != nil,
]

// The challenge is not a server challenge: the probe proves the device side only.
let challenge = Data("cmux-attest-probe-\(Date().timeIntervalSince1970)".utf8)
let clientDataHash = Data(SHA256.hash(data: challenge))

/// One POST to the cmux API: (status, error code or "ok").
func post(_ origin: String, _ path: String, _ body: [String: Any]) async -> (Int, String, [String: Any]) {
    guard let url = URL(string: origin + path) else { return (0, "bad origin", [:]) }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    guard let (data, response) = try? await URLSession.shared.data(for: request) else { return (0, "network", [:]) }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    let code = ((json["error"] as? [String: Any])?["code"] as? String) ?? (status == 200 ? "ok" : "unknown")
    return (status, code, json)
}

func challenge(_ origin: String) async -> String? {
    let (_, _, json) = await post(origin, "/v1/inference/free/challenge", [:])
    return json["challenge"] as? String
}

/// T3 to T5 of cx-ds09i against a deployment with this probe's app id allowed.
func freeFlow(origin: String) async -> [[String: Any]] {
    var steps: [[String: Any]] = []
    func record(_ name: String, _ outcome: (Int, String, [String: Any])) {
        steps.append(["step": name, "status": outcome.0, "code": outcome.1])
    }
    let service = DCAppAttestService.shared
    func attest(_ keyID: String, forge: Bool) async -> (Int, String, [String: Any]) {
        guard let c = await challenge(origin) else { return (0, "no challenge", [:]) }
        do {
            var attestation = try await service.attestKey(keyID, clientDataHash: Data(SHA256.hash(data: Data(c.utf8))))
            if forge { attestation[attestation.count / 2] ^= 0x01 }
            let token = try await DCDevice.current.generateToken()
            return await post(origin, "/v1/inference/free/attest", [
                "platform": "mac", "key_id": keyID, "challenge": c,
                "attestation": attestation.base64EncodedString(), "device_token": token.base64EncodedString(),
            ])
        } catch {
            return (0, "app \((error as NSError).code)", [:])
        }
    }
    do {
        // T3: a forged attestation (one byte changed) of a new key is refused.
        let forged = try await service.generateKey()
        record("forged_attestation", await attest(forged, forge: true))
        // A real attestation of a fresh key (the result depends on the device's bits this month).
        let key = try await service.generateKey()
        record("fresh_key_attestation", await attest(key, forge: false))
        // T4: an assertion renews once; the same request again is refused (replay).
        if let c = await challenge(origin) {
            let assertion = try await service.generateAssertion(key, clientDataHash: Data(SHA256.hash(data: Data(c.utf8))))
            let body: [String: Any] = ["key_id": key, "challenge": c, "assertion": assertion.base64EncodedString()]
            record("assertion", await post(origin, "/v1/inference/free/token", body))
            record("replayed_assertion", await post(origin, "/v1/inference/free/token", body))
        }
        // T5: one more new key on this device in the same month.
        let another = try await service.generateKey()
        record("another_new_key", await attest(another, forge: false))
    } catch {
        steps.append(["step": "generate_key", "error": (error as NSError).code])
    }
    return steps
}

let semaphore = DispatchSemaphore(value: 0)
// Detached: top-level code runs on the main thread, which the semaphore blocks.
Task.detached {
    defer { semaphore.signal() }
    let mode = args[1]
    let outDir = URL(fileURLWithPath: (mode == "assert" || mode == "attestkey" || mode == "freeflow") && args.count >= 4 ? args[3] : args[2])
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    result["mode"] = mode
    do {
        try save(challenge, outDir, "\(mode)-client-data.bin")
    } catch {
        result["save_error"] = describe(error)
    }

    if mode == "attest" {
        do {
            let keyID = try await DCAppAttestService.shared.generateKey()
            result["key_id"] = keyID
            do {
                let attestation = try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
                result["attestation_bytes"] = attestation.count
                try save(attestation, outDir, "attestation.cbor")
            } catch {
                result["attest_error"] = describe(error)
            }
            do {
                let assertion = try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
                result["assertion_bytes"] = assertion.count
                try save(assertion, outDir, "attest-assertion.cbor")
            } catch {
                result["first_assertion_error"] = describe(error)
            }
        } catch {
            result["generate_key_error"] = describe(error)
        }
    } else if mode == "assert" {
        let keyID = args[2]
        result["key_id"] = keyID
        do {
            let assertion = try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
            result["assertion_bytes"] = assertion.count
            try save(assertion, outDir, "reinstall-assertion.cbor")
        } catch {
            result["assertion_error"] = describe(error)
        }
    } else if mode == "reattest" {
        do {
            let keyID = try await DCAppAttestService.shared.generateKey()
            result["key_id"] = keyID
            for round in 1...2 {
                do {
                    let attestation = try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
                    result["attest\(round)_bytes"] = attestation.count
                    try save(attestation, outDir, "reattest-\(round).cbor")
                } catch {
                    result["attest\(round)_error"] = describe(error)
                }
            }
            do {
                let assertion = try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
                result["assertion_bytes"] = assertion.count
            } catch {
                result["assertion_error"] = describe(error)
            }
        } catch {
            result["generate_key_error"] = describe(error)
        }
    } else if mode == "freeflow" {
        result["steps"] = await freeFlow(origin: args[2])
    } else if mode == "attestkey" {
        let keyID = args[2]
        result["key_id"] = keyID
        do {
            let attestation = try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
            result["attest_bytes"] = attestation.count
            try save(attestation, outDir, "attestkey.cbor")
        } catch {
            result["attest_error"] = describe(error)
        }
        do {
            let assertion = try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
            result["assertion_bytes"] = assertion.count
        } catch {
            result["assertion_error"] = describe(error)
        }
    } else {
        result["error"] = "unknown mode"
        return
    }

    if DCDevice.current.isSupported {
        do {
            let token = try await DCDevice.current.generateToken()
            result["devicecheck_token_bytes"] = token.count
            try save(token, outDir, "\(mode)-devicecheck-token.bin")
        } catch {
            result["devicecheck_error"] = describe(error)
        }
    }
}
semaphore.wait()
emit(result)
// `open` does not pass stdout back: the same object goes to <out-dir>/<mode>-result.json.
if let outPath = args.last, let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
    try? data.write(to: URL(fileURLWithPath: outPath).appendingPathComponent("\(args[1])-result.json"))
}
