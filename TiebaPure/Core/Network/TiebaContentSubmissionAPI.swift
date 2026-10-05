import CryptoKit
import Foundation
import CoreFoundation
import SwiftProtobuf

struct TiebaAppUploadedImage: Equatable, Sendable {
    let picID: String
    let pixelWidth: Int
    let pixelHeight: Int

    var contentTag: String {
        "#(pic,\(picID),\(pixelWidth),\(pixelHeight))"
    }
}

struct TiebaImageUploadResponseDTO: Decodable, Equatable {
    private struct InfoDTO: Decodable, Equatable {
        let picID: String

        private enum CodingKeys: String, CodingKey {
            case picID = "pic_id"
            case fallbackPicID = "picId"
        }

        init(from decoder: Swift.Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            picID = container.submissionString(forKey: .picID)
                ?? container.submissionString(forKey: .fallbackPicID)
                ?? ""
        }
    }

    let errorCode: Int?
    let errorMessage: String
    let picID: String

    private enum CodingKeys: String, CodingKey {
        case errorCode = "error_code"
        case fallbackErrorCode = "err_code"
        case errorMessage = "error_msg"
        case fallbackErrorMessage = "err_msg"
        case picID = "picId"
        case fallbackPicID = "pic_id"
        case info
    }

    init(from decoder: Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        errorCode = container.submissionInt(forKey: .errorCode)
            ?? container.submissionInt(forKey: .fallbackErrorCode)
        errorMessage = container.submissionString(forKey: .errorMessage)
            ?? container.submissionString(forKey: .fallbackErrorMessage)
            ?? ""
        let info = try? container.decodeIfPresent(InfoDTO.self, forKey: .info)
        picID = container.submissionString(forKey: .picID)
            ?? container.submissionString(forKey: .fallbackPicID)
            ?? info?.picID
            ?? ""
    }

    func validatedPicID() throws -> String {
        guard let errorCode else {
            throw ContentSubmissionError.business(code: -1, message: "图片上传响应缺少状态码。")
        }
        guard errorCode == 0 else {
            if TiebaAPIError.isSessionExpired(code: errorCode, message: errorMessage) {
                throw ContentSubmissionError.sessionExpired
            }
            throw ContentSubmissionError.business(
                code: errorCode,
                message: errorMessage.isEmpty ? "图片上传失败。" : errorMessage
            )
        }

        let value = picID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false,
              value.utf8.count <= 2_048,
              value.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57)
                      || (byte >= 65 && byte <= 90)
                      || (byte >= 97 && byte <= 122)
                      || byte == 45
                      || byte == 95
              }) else {
            throw ContentSubmissionError.business(code: -1, message: "贴吧没有返回有效的图片标识。")
        }
        return value
    }
}

private struct TiebaWebThreadSubmissionResponseDTO: Decodable {
    private struct DataDTO: Decodable {
        let result: Int?
        let hasResult: Bool
        let errorCode: Int?
        let hasErrorCode: Bool
        let legacyErrorCode: Int?
        let hasLegacyErrorCode: Bool
        let threadIDs: [String]
        let postIDs: [String]
        let hasUnparseableIdentifier: Bool
        let message: String
        let challengePayload: TiebaWebSubmissionChallengePayload

        private enum CodingKeys: String, CodingKey {
            case result
            case errorCode = "error_code"
            case legacyErrorCode = "err_code"
            case threadID = "tid"
            case postID = "pid"
            case message = "msg"
        }

        init(from decoder: Swift.Decoder) throws {
            challengePayload = try TiebaWebSubmissionChallengePayload(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hasResult = container.contains(.result)
            result = container.submissionInt(forKey: .result)
            hasErrorCode = container.contains(.errorCode)
            errorCode = container.submissionInt(forKey: .errorCode)
            hasLegacyErrorCode = container.contains(.legacyErrorCode)
            legacyErrorCode = container.submissionInt(forKey: .legacyErrorCode)
            let threadID = container.submissionIdentifierString(forKey: .threadID)
            let postID = container.submissionIdentifierString(forKey: .postID)
            threadIDs = [threadID].compactMap { $0 }
            postIDs = [postID].compactMap { $0 }
            hasUnparseableIdentifier = [CodingKeys.threadID, .postID].contains {
                container.contains($0)
                    && container.submissionIdentifierString(forKey: $0)?
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            }
            message = container.submissionString(forKey: .message) ?? ""
        }
    }

    let result: Int?
    let hasResult: Bool
    let errorCode: Int?
    let hasErrorCode: Bool
    let legacyErrorCode: Int?
    let hasLegacyErrorCode: Bool
    let errorMessage: String
    let legacyErrorMessage: String
    let threadIDs: [String]
    let postIDs: [String]
    let hasUnparseableIdentifier: Bool
    private let challengePayload: TiebaWebSubmissionChallengePayload
    private let data: DataDTO?

    private enum CodingKeys: String, CodingKey {
        case result
        case errorCode = "error_code"
        case legacyErrorCode = "err_code"
        case errorMessage = "error_msg"
        case legacyErrorMessage = "err_msg"
        case threadID = "tid"
        case postID = "pid"
        case data
    }

    init(from decoder: Swift.Decoder) throws {
        challengePayload = try TiebaWebSubmissionChallengePayload(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedData = try? container.decodeIfPresent(DataDTO.self, forKey: .data)
        data = decodedData
        let topResult = container.submissionInt(forKey: .result)
        hasResult = container.contains(.result) || (decodedData?.hasResult ?? false)
        if let topResult, let nestedResult = decodedData?.result, topResult != nestedResult {
            result = nil
        } else {
            result = topResult ?? decodedData?.result
        }
        let topErrorCode = container.submissionInt(forKey: .errorCode)
        hasErrorCode = container.contains(.errorCode) || (decodedData?.hasErrorCode ?? false)
        if let topErrorCode,
           let nestedErrorCode = decodedData?.errorCode,
           topErrorCode != nestedErrorCode {
            errorCode = nil
        } else {
            errorCode = topErrorCode ?? decodedData?.errorCode
        }
        let topLegacyErrorCode = container.submissionInt(forKey: .legacyErrorCode)
        hasLegacyErrorCode = container.contains(.legacyErrorCode)
            || (decodedData?.hasLegacyErrorCode ?? false)
        if let topLegacyErrorCode,
           let nestedLegacyErrorCode = decodedData?.legacyErrorCode,
           topLegacyErrorCode != nestedLegacyErrorCode {
            legacyErrorCode = nil
        } else {
            legacyErrorCode = topLegacyErrorCode ?? decodedData?.legacyErrorCode
        }
        errorMessage = container.submissionString(forKey: .errorMessage) ?? ""
        legacyErrorMessage = container.submissionString(forKey: .legacyErrorMessage) ?? ""
        let threadID = container.submissionIdentifierString(forKey: .threadID)
        let postID = container.submissionIdentifierString(forKey: .postID)
        threadIDs = [threadID].compactMap { $0 } + (decodedData?.threadIDs ?? [])
        postIDs = [postID].compactMap { $0 } + (decodedData?.postIDs ?? [])
        hasUnparseableIdentifier = [CodingKeys.threadID, .postID].contains {
            container.contains($0)
                && container.submissionIdentifierString(forKey: $0)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        } || (decodedData?.hasUnparseableIdentifier ?? false)
    }

    var submissionReceipt: ContentSubmissionReceipt {
        get throws {
            // A present-but-unparseable status is not a trustworthy explicit
            // success or failure response after a write has been dispatched.
            guard (hasResult == false || result != nil),
                  (hasErrorCode == false || errorCode != nil),
                  (hasLegacyErrorCode == false || legacyErrorCode != nil) else {
                throw ContentSubmissionError.outcomeUnknown
            }

            let codes = [errorCode, legacyErrorCode].compactMap { $0 }
            guard Set(codes).count <= 1 else {
                throw ContentSubmissionError.outcomeUnknown
            }
            let code = codes.first
            let resultIsSuccess = result == 1
            let resultIsFailure = hasResult && resultIsSuccess == false
            let codeIsSuccess = code == 0
            let codeIsFailure = code.map { $0 != 0 } ?? false
            guard (resultIsSuccess && codeIsFailure) == false,
                  (resultIsFailure && codeIsSuccess) == false else {
                throw ContentSubmissionError.outcomeUnknown
            }

            let messages = normalizedSubmissionMessages([
                errorMessage,
                legacyErrorMessage,
                data?.message ?? ""
            ])
            let message = messages.first ?? ""
            if let code,
               code != 0,
               TiebaAPIError.isSessionExpired(code: code, message: message) {
                throw ContentSubmissionError.sessionExpired
            }
            if let challenge = TiebaWebSubmissionChallengePayload.challenge(
                from: [challengePayload] + [data?.challengePayload].compactMap { $0 },
                messages: messages
            ) {
                throw ContentSubmissionError.verificationRequired(challenge)
            }
            if let code, code != 0 {
                throw ContentSubmissionError.business(code: code, message: message)
            }
            if resultIsFailure {
                throw ContentSubmissionError.business(code: -1, message: message)
            }
            guard resultIsSuccess || codeIsSuccess else {
                throw ContentSubmissionError.outcomeUnknown
            }

            guard hasUnparseableIdentifier == false else {
                throw ContentSubmissionError.outcomeUnknown
            }
            let returnedThreadIDs = try validatedPositiveInt64Values(threadIDs)
            guard returnedThreadIDs.count == 1,
                  let resolvedThreadID = returnedThreadIDs.first else {
                throw ContentSubmissionError.outcomeUnknown
            }
            let returnedPostIDs = try validatedPositiveUInt64Values(postIDs)
            guard returnedPostIDs.count <= 1 else {
                throw ContentSubmissionError.outcomeUnknown
            }
            return ContentSubmissionReceipt(
                threadID: resolvedThreadID,
                postID: returnedPostIDs.first
            )
        }
    }
}

struct TiebaWebUploadPictureResponseDTO: Decodable, Equatable {
    let errorCode: Int?
    private let hasErrorCode: Bool
    let errorMessage: String
    let imageInfo: String

    private enum CodingKeys: String, CodingKey {
        case errorCode = "error_code"
        case legacyErrorCode = "err_code"
        case errorMessage = "error_msg"
        case camelErrorMessage = "errorMsg"
        case legacyErrorMessage = "err_msg"
        case legacyCamelErrorMessage = "errMsg"
        case imageInfo = "image_info"
        case camelImageInfo = "imageInfo"
    }

    init(from decoder: Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hasPrimaryCode = container.contains(.errorCode)
        let hasLegacyCode = container.contains(.legacyErrorCode)
        hasErrorCode = hasPrimaryCode || hasLegacyCode
        let primaryCode = container.submissionInt(forKey: .errorCode)
        let legacyCode = container.submissionInt(forKey: .legacyErrorCode)
        if let primaryCode, let legacyCode, primaryCode != legacyCode {
            errorCode = nil
        } else {
            errorCode = primaryCode ?? legacyCode
        }
        errorMessage = container.submissionString(forKey: .errorMessage)
            ?? container.submissionString(forKey: .camelErrorMessage)
            ?? container.submissionString(forKey: .legacyErrorMessage)
            ?? container.submissionString(forKey: .legacyCamelErrorMessage)
            ?? ""
        imageInfo = container.submissionString(forKey: .imageInfo)
            ?? container.submissionString(forKey: .camelImageInfo)
            ?? ""
    }

    func validatedImageInfo() throws -> String {
        guard hasErrorCode == false || errorCode != nil else {
            throw ContentSubmissionError.business(code: -1, message: "图片上传响应状态无效。")
        }
        if let errorCode, errorCode != 0 {
            if TiebaAPIError.isSessionExpired(code: errorCode, message: errorMessage) {
                throw ContentSubmissionError.sessionExpired
            }
            throw ContentSubmissionError.business(
                code: errorCode,
                message: errorMessage.isEmpty ? "图片上传失败。" : errorMessage
            )
        }
        let normalized = imageInfo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false,
              normalized.utf8.count <= 16_384,
              containsASCIIControlLineBreak(normalized) == false else {
            throw ContentSubmissionError.business(code: -1, message: "贴吧没有返回有效的图片信息。")
        }
        return normalized
    }
}

struct TiebaWebReplySubmissionResponseDTO: Decodable {
    private struct DataDTO: Decodable {
        let result: Int?
        let hasResult: Bool
        let codes: [Int]
        let hasUnparseableCode: Bool
        let messages: [String]
        let threadIDs: [String]
        let postIDs: [String]
        let hasUnparseableIdentifier: Bool
        let challengePayload: TiebaWebSubmissionChallengePayload

        private enum CodingKeys: String, CodingKey {
            case result
            case errorCode = "error_code"
            case legacyErrorCode = "err_code"
            case no
            case errno
            case errorNo = "error_no"
            case errorMessage = "error_msg"
            case legacyErrorMessage = "err_msg"
            case error
            case message = "msg"
            case threadID = "tid"
            case postID = "pid"
            case alternatePostID = "post_id"
        }

        init(from decoder: Swift.Decoder) throws {
            challengePayload = try TiebaWebSubmissionChallengePayload(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hasResult = container.contains(.result)
            result = container.submissionInt(forKey: .result)
            let codeKeys: [CodingKeys] = [.errorCode, .legacyErrorCode, .no, .errno, .errorNo]
            codes = codeKeys.compactMap { container.submissionInt(forKey: $0) }
            hasUnparseableCode = codeKeys.contains {
                container.contains($0) && container.submissionInt(forKey: $0) == nil
            }
            messages = [
                container.submissionString(forKey: .errorMessage),
                container.submissionString(forKey: .legacyErrorMessage),
                container.submissionString(forKey: .error),
                container.submissionString(forKey: .message)
            ].compactMap { $0 }
            let threadID = container.submissionIdentifierString(forKey: .threadID)
            let postID = container.submissionIdentifierString(forKey: .postID)
            let alternatePostID = container.submissionIdentifierString(forKey: .alternatePostID)
            threadIDs = [threadID].compactMap { $0 }
            postIDs = [postID, alternatePostID].compactMap { $0 }
            hasUnparseableIdentifier = (
                container.contains(.threadID)
                    && validSubmissionThreadIdentifier(threadID) == false
            ) || [
                (CodingKeys.postID, postID),
                (CodingKeys.alternatePostID, alternatePostID)
            ].contains { key, value in
                container.contains(key) && validSubmissionPostIdentifier(value) == false
            }
        }
    }

    private let result: Int?
    private let hasResult: Bool
    private let codes: [Int]
    private let hasUnparseableCode: Bool
    private let messages: [String]
    private let threadIDs: [String]
    private let postIDs: [String]
    private let hasUnparseableIdentifier: Bool
    private let challengePayload: TiebaWebSubmissionChallengePayload
    private let nestedChallengePayload: TiebaWebSubmissionChallengePayload?

    private enum CodingKeys: String, CodingKey {
        case result
        case errorCode = "error_code"
        case legacyErrorCode = "err_code"
        case no
        case errno
        case errorNo = "error_no"
        case errorMessage = "error_msg"
        case legacyErrorMessage = "err_msg"
        case error
        case message = "msg"
        case threadID = "tid"
        case postID = "pid"
        case alternatePostID = "post_id"
        case data
    }

    init(from decoder: Swift.Decoder) throws {
        challengePayload = try TiebaWebSubmissionChallengePayload(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let data = try? container.decodeIfPresent(DataDTO.self, forKey: .data)
        nestedChallengePayload = data?.challengePayload
        hasResult = container.contains(.result) || (data?.hasResult ?? false)
        let topResult = container.submissionInt(forKey: .result)
        if let topResult, let nestedResult = data?.result, topResult != nestedResult {
            result = nil
        } else {
            result = topResult ?? data?.result
        }
        let codeKeys: [CodingKeys] = [.errorCode, .legacyErrorCode, .no, .errno, .errorNo]
        codes = codeKeys.compactMap { container.submissionInt(forKey: $0) } + (data?.codes ?? [])
        hasUnparseableCode = codeKeys.contains {
            container.contains($0) && container.submissionInt(forKey: $0) == nil
        } || (data?.hasUnparseableCode ?? false)
        messages = [
            container.submissionString(forKey: .errorMessage),
            container.submissionString(forKey: .legacyErrorMessage),
            container.submissionString(forKey: .error),
            container.submissionString(forKey: .message)
        ].compactMap { $0 } + (data?.messages ?? [])
        let threadID = container.submissionIdentifierString(forKey: .threadID)
        let postID = container.submissionIdentifierString(forKey: .postID)
        let alternatePostID = container.submissionIdentifierString(forKey: .alternatePostID)
        threadIDs = [threadID].compactMap { $0 } + (data?.threadIDs ?? [])
        postIDs = [postID, alternatePostID].compactMap { $0 } + (data?.postIDs ?? [])
        hasUnparseableIdentifier = (
            container.contains(.threadID)
                && validSubmissionThreadIdentifier(threadID) == false
        ) || [
            (CodingKeys.postID, postID),
            (CodingKeys.alternatePostID, alternatePostID)
        ].contains { key, value in
            container.contains(key) && validSubmissionPostIdentifier(value) == false
        } || (data?.hasUnparseableIdentifier ?? false)
    }

    func submissionReceipt(for target: ContentSubmissionTarget) throws -> ContentSubmissionReceipt {
        guard let targetThreadID = target.threadID, targetThreadID > 0 else {
            throw ContentSubmissionError.outcomeUnknown
        }
        guard hasUnparseableCode == false,
              hasUnparseableIdentifier == false,
              (hasResult == false || result != nil) else {
            throw ContentSubmissionError.outcomeUnknown
        }
        let uniqueCodes = Set(codes)
        guard uniqueCodes.count <= 1 else {
            throw ContentSubmissionError.outcomeUnknown
        }
        let code = uniqueCodes.first
        let resultIsSuccess = result == 1
        let resultIsFailure = hasResult && resultIsSuccess == false
        let codeIsSuccess = code == 0
        let codeIsFailure = code.map { $0 != 0 } ?? false
        guard (resultIsSuccess && codeIsFailure) == false,
              (resultIsFailure && codeIsSuccess) == false else {
            throw ContentSubmissionError.outcomeUnknown
        }

        let normalizedMessages = normalizedSubmissionMessages(messages)
        let message = normalizedMessages.first ?? ""
        if let code, TiebaAPIError.isSessionExpired(code: code, message: message) {
            throw ContentSubmissionError.sessionExpired
        }
        if let challenge = TiebaWebSubmissionChallengePayload.challenge(
            from: [challengePayload] + [nestedChallengePayload].compactMap { $0 },
            messages: normalizedMessages
        ) {
            throw ContentSubmissionError.verificationRequired(challenge)
        }
        if let code, code != 0 {
            throw ContentSubmissionError.business(code: code, message: message)
        }
        if resultIsFailure {
            throw ContentSubmissionError.business(code: -1, message: message)
        }
        guard resultIsSuccess || codeIsSuccess else {
            throw ContentSubmissionError.outcomeUnknown
        }

        let returnedThreadIDs = try validatedPositiveInt64Values(threadIDs)
        guard returnedThreadIDs.isEmpty || returnedThreadIDs == [targetThreadID] else {
            throw ContentSubmissionError.outcomeUnknown
        }
        let returnedPostIDs = try validatedPositiveUInt64Values(postIDs)
        guard returnedPostIDs.count <= 1 else {
            throw ContentSubmissionError.outcomeUnknown
        }
        return ContentSubmissionReceipt(
            threadID: targetThreadID,
            postID: returnedPostIDs.first
        )
    }
}

enum TiebaContentSubmissionRequestFactory {
    static let clientVersion = "12.35.1.0"

    private static let webUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static func common(
        account: Account,
        tbs: String,
        bootstrap: TiebaPostingBootstrapResult,
        requestBuilder: TiebaRequestBuilder,
        now: Date = Date()
    ) -> Tieba_CommonRequest {
        let timestamp = Int64(now.timeIntervalSince1970 * 1_000)
        let firstRunTimestamp = max(1, timestamp - 30 * 86_400)
        let dateComponents = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day],
            from: now
        )

        var common = Tieba_CommonRequest()
        common.clientType = 2
        common.clientVersion = clientVersion
        common.clientID = bootstrap.clientID
        common.phoneImei = "000000000000000"
        common.from = "1008621x"
        common.cuid = bootstrap.identity.cuidGalaxy2
        common.timestamp = timestamp
        common.model = "SM-G988N"
        common.bduss = account.bduss
        common.tbs = tbs
        common.netType = 1
        common.pversion = "1.0.3"
        common.osVersion = "9"
        common.brand = "samsung"
        common.legoLibVersion = "3.0.0"
        common.applist = ""
        common.stoken = account.stoken
        common.zID = bootstrap.zID
        common.cuidGalaxy2 = bootstrap.identity.cuidGalaxy2
        common.c3Aid = bootstrap.identity.c3AID
        common.sampleID = bootstrap.sampleID
        common.scrW = 720
        common.scrH = 1_280
        common.scrDip = 1.5
        common.sdkVer = "2.34.0"
        common.frameworkVer = "3340042"
        common.nawsGameVer = "1038000"
        common.activeTimestamp = firstRunTimestamp
        common.firstInstallTime = firstRunTimestamp
        common.lastUpdateTime = firstRunTimestamp
        common.eventDay = [dateComponents.year, dateComponents.month, dateComponents.day]
            .compactMap { $0.map(String.init) }
            .joined()
        common.androidID = bootstrap.identity.androidID
        common.cmode = 1
        common.startScheme = ""
        common.startType = 1
        common.idfv = "0"
        common.extra = ""
        common.userAgent = "tieba/\(clientVersion) skin/default TiebaPure/\(appVersion)"
        common.personalizedRecSwitch = 1
        common.deviceScore = "0.4"
        return common
    }

    static func addPost(
        account: Account,
        tbs: String,
        request: ContentSubmissionRequest,
        uploadedImages: [TiebaAppUploadedImage],
        bootstrap: TiebaPostingBootstrapResult,
        requestBuilder: TiebaRequestBuilder,
        now: Date = Date()
    ) throws -> Tieba_AddPostRequest {
        guard let threadID = request.target.threadID, threadID > 0 else {
            throw ContentSubmissionValidationError.invalidThread
        }

        var data = Tieba_AddPostRequest.DataMessage()
        data.common = common(
            account: account,
            tbs: tbs,
            bootstrap: bootstrap,
            requestBuilder: requestBuilder,
            now: now
        )
        data.anonymous = "1"
        data.canNoForum = "0"
        data.isFeedback = "0"
        data.takephotoNum = String(uploadedImages.count)
        data.entranceType = "0"
        data.vcodeTag = "12"
        data.newVcode = "1"
        let body = request.target.kind == .subpostReply
            ? subpostReplyBody(request.body, target: request.target)
            : request.body
        data.content = content(body: body, uploadedImages: uploadedImages)
        data.fid = String(request.target.forumID)
        data.vFid = ""
        data.vFname = ""
        data.kw = request.target.forumName
        data.isBarrage = "0"
        data.fromFourmID = String(request.target.forumID)
        data.tid = String(threadID)
        data.isAd = "0"
        data.nameShow = account.displayName.isEmpty ? account.name : account.displayName
        data.isPictxt = uploadedImages.isEmpty ? "0" : "1"

        switch request.target.kind {
        case .threadReply:
            data.barrageTime = "0"
            data.postFrom = "3"
        case .postReply:
            try applyFloorReplyTarget(request.target, to: &data)
            data.postFrom = "0"
        case .subpostReply:
            try applyFloorReplyTarget(request.target, to: &data)
            guard let subpostID = request.target.subpostID, subpostID > 0 else {
                throw ContentSubmissionValidationError.invalidThread
            }
            data.subPostID = String(subpostID)
        case .newThread:
            throw ContentSubmissionError.unsupported(message: "新主题必须使用发帖协议。")
        }

        var protobuf = Tieba_AddPostRequest()
        protobuf.data = data
        return protobuf
    }

    static func webThreadFields(
        account: Account,
        tbs: String,
        request: ContentSubmissionRequest,
        now: Date = Date()
    ) throws -> [String: String] {
        guard request.target.kind == .newThread else {
            throw ContentSubmissionError.unsupported(message: "回复不能使用网页发帖协议。")
        }
        guard request.images.isEmpty else {
            throw ContentSubmissionValidationError.imagesUnsupportedForNewThread
        }
        guard tbs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw TiebaMutationError.missingTBS
        }
        return [
            "ie": "utf-8",
            "fid": String(request.target.forumID),
            "kw": request.target.forumName,
            "tbs": tbs,
            "title": request.title,
            "content": request.body,
            "nick_name": account.displayName.isEmpty ? account.name : account.displayName,
            "bsk": String(Int64(now.timeIntervalSince1970 * 1_000))
        ]
    }

    static func webReplyFields(
        account: Account,
        tbs: String,
        request: ContentSubmissionRequest,
        uploadedImageInfo: String,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) throws -> [String: String] {
        guard request.target.kind != .newThread,
              let threadID = request.target.threadID,
              threadID > 0 else {
            throw ContentSubmissionValidationError.invalidThread
        }
        let resolvedTBS = tbs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resolvedTBS.isEmpty == false else {
            throw TiebaMutationError.missingTBS
        }
        let imageInfo = uploadedImageInfo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard imageInfo.utf8.count <= ContentSubmissionPolicy.maximumImages * 16_384,
              containsASCIIControlLineBreak(imageInfo) == false else {
            throw ContentSubmissionValidationError.invalidImage
        }

        var fields = [
            "co": webReplyBody(request.body, target: request.target),
            "_t": String(timestamp),
            "tag": "11",
            "upload_img_info": imageInfo,
            "fid": String(request.target.forumID),
            "src": "1",
            "word": request.target.forumName,
            "tbs": resolvedTBS,
            "z": String(threadID),
            "lp": "6026",
            "nick_name": account.displayName.isEmpty ? account.name : account.displayName,
            "_BSK": String(timestamp)
        ]

        switch request.target.kind {
        case .threadReply:
            break
        case .postReply, .subpostReply:
            guard let parentPostID = request.target.parentPostID, parentPostID > 0 else {
                throw ContentSubmissionValidationError.invalidThread
            }
            fields["pid"] = String(parentPostID)
            fields["floor"] = String(max(1, request.target.parentFloor ?? 1))
            if request.target.kind == .subpostReply {
                guard let subpostID = request.target.subpostID, subpostID > 0 else {
                    throw ContentSubmissionValidationError.invalidThread
                }
                fields["lzl_id"] = String(subpostID)
            }
        case .newThread:
            throw ContentSubmissionError.unsupported(message: "新主题不能使用网页回帖协议。")
        }
        return fields
    }

    static func appHeaders(
        bootstrap: TiebaPostingBootstrapResult,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) -> [String: String] {
        [
            "Accept": "*/*",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "Pragma": "no-cache",
            "User-Agent": "tieba/\(clientVersion) skin/default TiebaPure/\(appVersion)",
            "client_logid": String(timestamp),
            "client_type": "2",
            "cuid": bootstrap.identity.cuidGalaxy2,
            "cuid_galaxy2": bootstrap.identity.cuidGalaxy2,
            "cuid_gid": ""
        ]
    }

    static func postProtobufHeaders(
        bootstrap: TiebaPostingBootstrapResult,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) -> [String: String] {
        var headers = appHeaders(bootstrap: bootstrap, timestamp: timestamp)
        headers["x_bd_data_type"] = "protobuf"
        return headers
    }

    static func webThreadHeaders(
        account: Account,
        forumName: String
    ) throws -> [String: String] {
        var referer = URLComponents(url: TiebaEndpoint.base.appending(path: "/f"), resolvingAgainstBaseURL: false)
        referer?.queryItems = [.init(name: "kw", value: forumName)]
        return try webMutationHeaders(
            account: account,
            referer: referer?.url?.absoluteString ?? TiebaEndpoint.base.absoluteString
        )
    }

    static func webReplyHeaders(
        account: Account,
        threadID: Int64
    ) throws -> [String: String] {
        guard threadID > 0 else {
            throw ContentSubmissionValidationError.invalidThread
        }
        return try webMutationHeaders(
            account: account,
            referer: "https://tieba.baidu.com/p/\(threadID)?lp=5028&mo_device=1&is_jingpost=0&pn=1&"
        )
    }

    static func webUploadHeaders(
        account: Account,
        threadID: Int64
    ) throws -> [String: String] {
        try webReplyHeaders(account: account, threadID: threadID)
    }

    private static func webMutationHeaders(
        account: Account,
        referer: String?
    ) throws -> [String: String] {
        var headers = try webBaseHeaders(account: account)
        headers["Origin"] = TiebaEndpoint.base.absoluteString
        headers["X-Requested-With"] = "XMLHttpRequest"
        if let referer {
            headers["Referer"] = referer
        }
        return headers
    }

    private static func webBaseHeaders(account: Account) throws -> [String: String] {
        guard BaiduCredentialPolicy.isValid(account) else {
            throw ContentSubmissionError.sessionExpired
        }
        return [
            "Accept": "application/json, text/plain, */*",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "Cache-Control": "no-cache",
            "Pragma": "no-cache",
            "User-Agent": webUserAgent,
            // The web publishing endpoints need only these validated credentials.
            // Keep BAIDUID out of write requests to minimize disclosure.
            "Cookie": "BDUSS=\(account.bduss); STOKEN=\(account.stoken)"
        ]
    }

    private static func applyFloorReplyTarget(
        _ target: ContentSubmissionTarget,
        to data: inout Tieba_AddPostRequest.DataMessage
    ) throws {
        guard let parentPostID = target.parentPostID, parentPostID > 0 else {
            throw ContentSubmissionValidationError.invalidThread
        }
        data.quoteID = String(parentPostID)
        data.repostid = String(parentPostID)
        if let replyUserID = target.replyUserID, replyUserID > 0 {
            data.replyUid = String(replyUserID)
        }
    }

    private static func content(
        body: String,
        uploadedImages: [TiebaAppUploadedImage]
    ) -> String {
        let imageTags = uploadedImages.map(\.contentTag)
        if body.isEmpty { return imageTags.joined(separator: "\n") }
        if imageTags.isEmpty { return body }
        return ([body] + imageTags).joined(separator: "\n")
    }

    private static func subpostReplyBody(
        _ body: String,
        target: ContentSubmissionTarget
    ) -> String {
        guard let displayName = protocolReplyComponent(target.replyUserDisplayName) else {
            return body
        }
        // Drafts written before reply portraits were persisted still carry the
        // target UID and display name. Keep the three-component protocol shape;
        // reply_uid lets the server restore ownership when portrait is absent.
        let portrait = protocolReplyComponent(target.replyUserPortrait) ?? ""
        return "回复 #(reply, \(portrait), \(displayName)) :\(body)"
    }

    private static func webReplyBody(
        _ body: String,
        target: ContentSubmissionTarget
    ) -> String {
        guard target.kind == .subpostReply,
              let displayName = protocolReplyComponent(target.replyUserDisplayName) else {
            return body
        }
        return "回复 \(displayName) : \(body)"
    }

    private static func protocolReplyComponent(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false,
              normalized.utf8.count <= 512,
              normalized.contains(",") == false,
              normalized.contains(")") == false,
              containsASCIIControlLineBreak(normalized) == false else {
            return nil
        }
        return normalized
    }
}

private func containsASCIIControlLineBreak(_ value: String) -> Bool {
    value.unicodeScalars.contains { scalar in
        scalar.value == 0x0A || scalar.value == 0x0D
    }
}

extension TiebaAPI {
    func submitContent(
        account: Account,
        request: ContentSubmissionRequest
    ) async throws -> ContentSubmissionReceipt {
        try ContentSubmissionPolicy.validateForNetwork(request)
        try Task.checkCancellation()

        if request.target.kind == .newThread {
            return try await submitWebThread(account: account, request: request)
        }
        return try await submitWebReply(account: account, request: request)
    }

    func strictlyRefreshedPostingTBS(for account: Account) async throws -> String {
        guard BaiduCredentialPolicy.isValid(account) else {
            throw ContentSubmissionError.sessionExpired
        }
        let response: LoginResponseDTO
        do {
            response = try await writeTokenLogin(bduss: account.bduss)
        } catch is CancellationError {
            throw CancellationError()
        } catch where Task.isCancelled {
            throw CancellationError()
        } catch {
            throw error
        }

        try Task.checkCancellation()
        let code = Int(response.errorCode ?? "0") ?? -1
        guard code == 0 else {
            do {
                try TiebaResponseValidator.validate(
                    code: code,
                    message: response.errorMessage ?? ""
                )
            } catch let error as TiebaAPIError {
                if case .sessionExpired = error {
                    throw ContentSubmissionError.sessionExpired
                }
                throw ContentSubmissionError.business(
                    code: code,
                    message: "发布登录校验失败（\(code)）：\(response.errorMessage ?? "")"
                )
            }
            throw ContentSubmissionError.business(
                code: code,
                message: response.errorMessage ?? ""
            )
        }
        let tbs = response.anti?.tbs.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard tbs.isEmpty == false else {
            throw TiebaMutationError.missingTBS
        }
        return tbs
    }

    private func sendFinalMutation<Response: SwiftProtobuf.Message>(
        endpoint: TiebaEndpoint,
        body: Data,
        contentType: String,
        headers: [String: String]
    ) async throws -> Response {
        // Before this point cancellation is known to be safe. Once the POST is
        // dispatched the server may have accepted it even if the client task is
        // cancelled or loses its response, so the operation must never look
        // retryable to the caller.
        try Task.checkCancellation()
        do {
            return try await client.postProtobuf(
                endpoint,
                body: body,
                contentType: contentType,
                headers: headers,
                as: Response.self
            )
        } catch {
            // The write may already have reached Tieba. Never retry it automatically.
            throw ContentSubmissionError.outcomeUnknown
        }
    }

    private func submitWebThread(
        account: Account,
        request: ContentSubmissionRequest
    ) async throws -> ContentSubmissionReceipt {
        let refreshedTBS = try await strictlyRefreshedPostingTBS(for: account)
        try Task.checkCancellation()
        let fields = try TiebaContentSubmissionRequestFactory.webThreadFields(
            account: account,
            tbs: refreshedTBS,
            request: request
        )
        let headers = try TiebaContentSubmissionRequestFactory.webThreadHeaders(
            account: account,
            forumName: request.target.forumName
        )

        // Once this POST starts, losing or failing to decode the response does
        // not prove the server rejected the thread. Never retry or fall back to
        // the app Protobuf endpoint after this point.
        try Task.checkCancellation()
        let response: TiebaWebThreadSubmissionResponseDTO
        do {
            let data = try await client.postFormData(
                .webAddThread,
                fields: fields,
                headers: headers
            )
            try validateStrictSubmissionIntegerTypes(in: data, kind: .thread)
            response = try JSONDecoder().decode(
                TiebaWebThreadSubmissionResponseDTO.self,
                from: data
            )
        } catch {
            throw ContentSubmissionError.outcomeUnknown
        }
        return try response.submissionReceipt
    }

    private func submitWebReply(
        account: Account,
        request: ContentSubmissionRequest
    ) async throws -> ContentSubmissionReceipt {
        let threadID = request.target.threadID ?? 0
        let uploadedImageInfo = try await uploadWebImages(
            request.images,
            account: account,
            threadID: threadID
        )
        try Task.checkCancellation()

        let refreshedTBS: String
        do {
            refreshedTBS = try await strictlyRefreshedPostingTBS(for: account)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TiebaAPIError {
            if case .sessionExpired = error {
                throw ContentSubmissionError.sessionExpired
            }
            throw error
        }
        try Task.checkCancellation()

        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        let fields = try TiebaContentSubmissionRequestFactory.webReplyFields(
            account: account,
            tbs: refreshedTBS,
            request: request,
            uploadedImageInfo: uploadedImageInfo,
            timestamp: timestamp
        )
        let headers = try TiebaContentSubmissionRequestFactory.webReplyHeaders(
            account: account,
            threadID: threadID
        )

        // From this point the server may have accepted the reply even if the
        // connection or local task ends before a response is decoded.
        try Task.checkCancellation()
        let response: TiebaWebReplySubmissionResponseDTO
        do {
            let data = try await client.postFormData(
                .webAddPost(timestamp: timestamp),
                fields: fields,
                headers: headers
            )
            try validateStrictSubmissionIntegerTypes(in: data, kind: .reply)
            response = try JSONDecoder().decode(
                TiebaWebReplySubmissionResponseDTO.self,
                from: data
            )
        } catch {
            throw ContentSubmissionError.outcomeUnknown
        }
        return try response.submissionReceipt(for: request.target)
    }

    private func uploadWebImages(
        _ images: [ContentSubmissionImage],
        account: Account,
        threadID: Int64
    ) async throws -> String {
        guard images.isEmpty == false else { return "" }
        let headers = try TiebaContentSubmissionRequestFactory.webUploadHeaders(
            account: account,
            threadID: threadID
        )
        var imageInfo: [String] = []
        imageInfo.reserveCapacity(images.count)
        for (index, image) in images.enumerated() {
            try Task.checkCancellation()
            _ = try ContentSubmissionImageInspector.inspect(image.data)
            let nonce = "\(Int64(Date().timeIntervalSince1970 * 1_000))_\(index)"
            do {
                let response = try await client.postForm(
                    .webUploadPicture(nonce: nonce),
                    fields: ["pic": image.data.base64EncodedString()],
                    headers: headers,
                    as: TiebaWebUploadPictureResponseDTO.self
                )
                imageInfo.append(try response.validatedImageInfo())
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ContentSubmissionError {
                throw error
            } catch where Task.isCancelled {
                throw CancellationError()
            } catch {
                throw ContentSubmissionError.business(
                    code: -1,
                    message: "图片上传失败，请检查网络后重试。"
                )
            }
        }
        return imageInfo.joined(separator: "|")
    }

    private func uploadImages(
        _ images: [ContentSubmissionImage],
        account: Account,
        bootstrap: TiebaPostingBootstrapResult
    ) async throws -> [TiebaAppUploadedImage] {
        var result: [TiebaAppUploadedImage] = []
        result.reserveCapacity(images.count)
        for image in images {
            try Task.checkCancellation()
            let metadata = try ContentSubmissionImageInspector.inspect(image.data)
            let picID = try await uploadImage(
                image.data,
                metadata: metadata,
                account: account,
                bootstrap: bootstrap
            )
            result.append(TiebaAppUploadedImage(
                picID: picID,
                pixelWidth: metadata.pixelWidth,
                pixelHeight: metadata.pixelHeight
            ))
        }
        return result
    }

    private func uploadImage(
        _ image: Data,
        metadata: ContentSubmissionImageMetadata,
        account: Account,
        bootstrap: TiebaPostingBootstrapResult
    ) async throws -> String {
        let digest = Insecure.MD5.hash(data: image)
            .map { String(format: "%02X", $0) }
            .joined()
        let boundary = "TiebaPureImage-\(UUID().uuidString)"
        let form = MultipartFormData(boundary: boundary)
        form.addField(name: "BDUSS", value: account.bduss)
        form.addField(name: "_client_type", value: "2")
        form.addField(name: "_client_version", value: TiebaContentSubmissionRequestFactory.clientVersion)
        form.addField(name: "alt", value: "json")
        form.addField(name: "chunkNo", value: "1")
        form.addField(name: "groupId", value: "1")
        form.addField(name: "height", value: String(metadata.pixelHeight))
        form.addField(name: "isFinish", value: "1")
        form.addField(name: "is_bjh", value: "0")
        form.addField(name: "resourceId", value: digest)
        form.addField(name: "saveOrigin", value: "1")
        form.addField(name: "stoken", value: account.stoken)
        form.addField(name: "support_image", value: "jepgwebp")
        form.addField(name: "width", value: String(metadata.pixelWidth))
        form.addFile(name: "chunk", filename: "image_\(digest.lowercased())", data: image)

        do {
            var headers = TiebaContentSubmissionRequestFactory.appHeaders(bootstrap: bootstrap)
            headers["Cookie"] = "ka=open"
            let raw = try await client.postRaw(
                .uploadPicture,
                body: form.finalize(),
                contentType: "multipart/form-data; boundary=\(boundary)",
                headers: headers
            )
            let response = try JSONDecoder().decode(TiebaImageUploadResponseDTO.self, from: raw)
            return try response.validatedPicID()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ContentSubmissionError {
            throw error
        } catch where Task.isCancelled {
            throw CancellationError()
        } catch {
            throw ContentSubmissionError.business(code: -1, message: "图片上传失败，请检查网络后重试。")
        }
    }
}

private extension TiebaPostingBootstrapError {
    var invalidatesPostingSession: Bool {
        switch self {
        case .invalidCredential:
            return true
        case let .server(code, message):
            return TiebaAPIError.isSessionExpired(code: code, message: message)
        default:
            return false
        }
    }
}

private extension Tieba_AddPostResponse {
    func submissionReceipt(for target: ContentSubmissionTarget) throws -> ContentSubmissionReceipt {
        guard hasError else {
            throw ContentSubmissionError.outcomeUnknown
        }
        let messages = submissionMessages
        try validateSubmissionStatus(
            error: error,
            verification: data.info,
            messages: messages
        )
        // AddPost success responses commonly contain only Error{error_code=0}.
        // The requested thread is therefore the stable source of the receipt;
        // returned identifiers are optional enrichment, not success evidence.
        guard let threadID = positiveInt64(data.tid) ?? target.threadID,
              threadID > 0 else {
            throw ContentSubmissionError.outcomeUnknown
        }
        return ContentSubmissionReceipt(
            threadID: threadID,
            postID: positiveUInt64(data.pid)
        )
    }

    var submissionMessages: [String] {
        normalizedSubmissionMessages([
            error.userMsg,
            error.errorMsg,
            data.msg,
            data.preMsg,
            data.colorMsg
        ])
    }
}

private func validateSubmissionStatus(
    error: Tieba_Error,
    verification: Tieba_SubmissionVerificationInfo,
    messages: [String]
) throws {
    let code = Int(error.errorCode)
    let message = messages.first ?? ""
    if TiebaAPIError.isSessionExpired(code: code, message: message) {
        throw ContentSubmissionError.sessionExpired
    }
    if verification.requiresVerification
        || messages.contains(where: \.requiresSubmissionVerification) {
        let challenge = ContentSubmissionChallenge(
            message: message,
            verificationMD5: SubmissionSecret(verification.vcodeMd5),
            verificationType: verification.vcodeType,
            pictureURL: validatedBaiduChallengeURL(verification.vcodePicURL)
        )
        throw ContentSubmissionError.verificationRequired(challenge)
    }
    guard code == 0 else {
        throw ContentSubmissionError.business(code: code, message: message)
    }
}

private extension Tieba_SubmissionVerificationInfo {
    var requiresVerification: Bool {
        let value = needVcode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (value.isEmpty == false && value != "0" && value != "false")
            || SubmissionSecret(vcodeMd5) != nil
            || vcodePicURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

private enum SubmissionStatusResponseKind {
    case thread
    case reply

    var integerKeys: Set<String> {
        switch self {
        case .thread:
            return ["result", "error_code", "err_code", "tid", "pid"]
        case .reply:
            return [
                "result", "error_code", "err_code", "no", "errno", "error_no",
                "tid", "pid", "post_id"
            ]
        }
    }
}

/// JSONDecoder accepts integral floating-point tokens such as `1.0` when
/// decoding an Int. Mutation statuses and identifiers determine whether a
/// dispatched write is considered successful, so inspect their raw JSON types
/// before decoding and accept only integer JSON numbers or integer strings.
private func validateStrictSubmissionIntegerTypes(
    in data: Data,
    kind: SubmissionStatusResponseKind
) throws {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ContentSubmissionError.outcomeUnknown
    }
    var containers = [object]
    if let nestedValue = object["data"], nestedValue is NSNull == false {
        guard let nested = nestedValue as? [String: Any] else {
            throw ContentSubmissionError.outcomeUnknown
        }
        containers.append(nested)
    }
    for container in containers {
        for key in kind.integerKeys {
            guard let value = container[key] else { continue }
            guard isStrictSubmissionInteger(value) else {
                throw ContentSubmissionError.outcomeUnknown
            }
        }
    }
}

private func isStrictSubmissionInteger(_ value: Any) -> Bool {
    if let value = value as? String {
        return Int(value) != nil
    }
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID() else {
        return false
    }
    switch String(cString: number.objCType) {
    case "c", "s", "i", "l", "q", "C", "S", "I", "L", "Q":
        return true
    default:
        return false
    }
}

private extension String {
    var requiresSubmissionVerification: Bool {
        let value = lowercased()
        return value.contains("验证码")
            || value.contains("安全验证")
            || value.contains("captcha")
            || value.contains("verify")
    }
}

private func normalizedSubmissionMessages(_ values: [String]) -> [String] {
    values
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { $0.isEmpty == false }
}

private func validatedPositiveInt64Values(_ values: [String]) throws -> Set<Int64> {
    var result = Set<Int64>()
    for value in values {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { continue }
        guard let parsed = positiveInt64(normalized) else {
            throw ContentSubmissionError.outcomeUnknown
        }
        result.insert(parsed)
    }
    return result
}

private func validatedPositiveUInt64Values(_ values: [String]) throws -> Set<UInt64> {
    var result = Set<UInt64>()
    for value in values {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { continue }
        guard let parsed = positiveUInt64(normalized) else {
            throw ContentSubmissionError.outcomeUnknown
        }
        result.insert(parsed)
    }
    return result
}

private func positiveInt64(_ value: String) -> Int64? {
    guard let number = Int64(value), number > 0 else { return nil }
    return number
}

private func positiveUInt64(_ value: String) -> UInt64? {
    guard let number = UInt64(value), number > 0 else { return nil }
    return number
}

private func validSubmissionThreadIdentifier(_ value: String?) -> Bool {
    guard let value else { return false }
    return positiveInt64(value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
}

private func validSubmissionPostIdentifier(_ value: String?) -> Bool {
    guard let value else { return false }
    return positiveUInt64(value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
}

private extension KeyedDecodingContainer {
    func submissionIdentifierString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(UInt64.self, forKey: key) {
            return String(value)
        }
        return nil
    }

    func submissionString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(UInt64.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value ? "1" : "0"
        }
        return nil
    }

    func submissionInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value)
        }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return Int(exactly: value)
        }
        if let value = try? decodeIfPresent(UInt64.self, forKey: key) {
            return Int(exactly: value)
        }
        return nil
    }
}
