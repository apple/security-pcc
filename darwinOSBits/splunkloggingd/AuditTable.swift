// Copyright © 2026 Apple Inc. All Rights Reserved.

// APPLE INC.
// PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT
// PLEASE READ THE FOLLOWING PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT (“AGREEMENT”) CAREFULLY BEFORE DOWNLOADING OR USING THE APPLE SOFTWARE ACCOMPANYING THIS AGREEMENT(AS DEFINED BELOW). BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING TO BE BOUND BY THE TERMS OF THIS AGREEMENT. IF YOU DO NOT AGREE TO THE TERMS OF THIS AGREEMENT, DO NOT DOWNLOAD OR USE THE APPLE SOFTWARE. THESE TERMS AND CONDITIONS CONSTITUTE A LEGAL AGREEMENT BETWEEN YOU AND APPLE.
// IMPORTANT NOTE: BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING ON YOUR OWN BEHALF AND/OR ON BEHALF OF YOUR COMPANY OR ORGANIZATION TO THE TERMS OF THIS AGREEMENT.
// 1. As used in this Agreement, the term “Apple Software” collectively means and includes all of the Apple Private Cloud Compute materials provided by Apple here, including but not limited to the Apple Private Cloud Compute software, tools, data, files, frameworks, libraries, documentation, logs and other Apple-created materials. In consideration for your agreement to abide by the following terms, conditioned upon your compliance with these terms and subject to these terms, Apple grants you, for a period of ninety (90) days from the date you download the Apple Software, a limited, non-exclusive, non-sublicensable license under Apple’s copyrights in the Apple Software to download, install, compile and run the Apple Software internally within your organization only on a single Apple-branded computer you own or control, for the sole purpose of verifying the security and privacy characteristics of Apple Private Cloud Compute. This Agreement does not allow the Apple Software to exist on more than one Apple-branded computer at a time, and you may not distribute or make the Apple Software available over a network where it could be used by multiple devices at the same time. You may not, directly or indirectly, redistribute the Apple Software or any portions thereof. The Apple Software is only licensed and intended for use as expressly stated above and may not be used for other purposes or in other contexts without Apple's prior written permission. Except as expressly stated in this notice, no other rights or licenses, express or implied, are granted by Apple herein.
// 2. The Apple Software is provided by Apple on an "AS IS" basis. APPLE MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS, SYSTEMS, OR SERVICES. APPLE DOES NOT WARRANT THAT THE APPLE SOFTWARE WILL MEET YOUR REQUIREMENTS, THAT THE OPERATION OF THE APPLE SOFTWARE WILL BE UNINTERRUPTED OR ERROR-FREE, THAT DEFECTS IN THE APPLE SOFTWARE WILL BE CORRECTED, OR THAT THE APPLE SOFTWARE WILL BE COMPATIBLE WITH FUTURE APPLE PRODUCTS, SOFTWARE OR SERVICES. NO ORAL OR WRITTEN INFORMATION OR ADVICE GIVEN BY APPLE OR AN APPLE AUTHORIZED REPRESENTATIVE WILL CREATE A WARRANTY.
// 3. IN NO EVENT SHALL APPLE BE LIABLE FOR ANY DIRECT, SPECIAL, INDIRECT, INCIDENTAL OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION, COMPILATION OR OPERATION OF THE APPLE SOFTWARE, HOWEVER CAUSED AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
// 4. This Agreement is effective until terminated. Your rights under this Agreement will terminate automatically without notice from Apple if you fail to comply with any term(s) of this Agreement. Upon termination, you agree to cease all use of the Apple Software and destroy all copies, full or partial, of the Apple Software. This Agreement constitutes the entire understanding of the parties with respect to the subject matter contained herein, and supersedes all prior negotiations, representations, or understandings, written or oral. This Agreement will be governed and construed in accordance with the laws of the State of California, without regard to its choice of law rules.
// You may report security issues about Apple products to product-security@apple.com, as described here: https://www.apple.com/support/security/. Non-security bugs and enhancement requests can be made via https://bugreport.apple.com as described here: https://developer.apple.com/bug-reporting/
// EA1937
// 10/02/2024

//
//  AuditTable.swift
//  splunkloggingd
//
//  Copyright © 2024 Apple, Inc.  All rights reserved.
//

/*
 ************************ Expected audit table format ************************
 *
 * Bracketed keys are variable, un-bracketed are static. All values variable
 * Note top level Senders key, in case audit table needs more keys later
 *
 * {
 *     "Senders": { // True to allow all logs from all senders
 *         "<sender>": {  // True to allow all logs from this sender
 *             "RequiredSubsystems": { // OPTIONAL
 *                 // Require sub1:cat1 OR sub1:cat2 OR sub2:any category
 *                 "<sub1>": [<cat1>, <cat2>], // list of categories
 *                 "<sub2>": True,
 *             }
 *             "BlanketAllowedSubsystems": { // OPTIONAL
 *                 // Allow all format strings from sub3:cat3, sub3:cat4, AND sub4:all categories
 *                 "<sub3>": [<cat3>, <cat4>], // list of categories
 *                 "<sub4>": True,
 *             },
 *             "FormatStrings": { // REQUIRED
 *                 <format string>: {
 *                     "AuditState": "Allowed" || "Denied" || "UnAudited"
 *
 *                     // Ordered list of names to match against the format args to the message
 *                     "ArgumentNames": [String], // OPTIONAL
 *
 *                     // If true, will not forward the composed message. Useful for de-duping data from large messages
 *                     // where most of the data is sent as structured args.
 *                     "DropComposedMessage": Bool // OPTIONAL
 *                 }
 *             }
 *         }
 *     }
 * }
 */

import Foundation
import LoggingSupport
import os

fileprivate let log = Logger(subsystem: sharedSubsystem, category: "AuditTable")

enum AuditState: String, Decodable {
    case Allowed, Denied, UnAudited
}

struct FormatStringData: Decodable {
    var state: AuditState
    var dropComposedMessage: Bool?
    var argNames: [String]?
    enum CodingKeys : String, CodingKey {
        case state = "AuditState"
        case argNames = "ArgumentNames"
        case dropComposedMessage = "DropComposedMessage"
    }
}

enum SubsystemEnum: Decodable {
    case all(val: Bool)
    case some(val: [String]) // Array of categories

    init (from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let val = try? container.decode(Bool.self) {
            if !val {
                let context = DecodingError.Context(codingPath: container.codingPath, debugDescription: "Cannot pass false for a subsystem")
                throw DecodingError.dataCorrupted(context)
            }
            self = .all(val: val)
        } else {
            self = .some(val: try container.decode([String].self))
        }
    }
}

struct SenderData: Decodable {
    var formatStrings: [String: FormatStringData]
    var blanketAllowedSubsystems: [String: SubsystemEnum]?
    var requiredSubsystems: [String: SubsystemEnum]?
    enum CodingKeys: String, CodingKey {
        case formatStrings = "FormatStrings"
        case blanketAllowedSubsystems = "BlanketAllowedSubsystems"
        case requiredSubsystems = "RequiredSubsystems"
    }
}

enum SenderEnum: Decodable {
    case allowAll(val: Bool)
    case allowSome(val: SenderData)

    init (from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let val = try? container.decode(Bool.self) {
            if !val {
                let context = DecodingError.Context(codingPath: container.codingPath, debugDescription: "Cannot pass false for individual sender")
                throw DecodingError.dataCorrupted(context)
            }
            self = .allowAll(val: val)
        } else {
            self = .allowSome(val: try container.decode(SenderData.self))
        }
    }
}

// Can pass True instead of a dict of senders to denote "allow everything"
enum AllSendersEnum : Decodable {
    case allowAll(val: Bool)
    case allowSome(val: [String:SenderEnum])

    init (from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let val = try? container.decode(Bool.self) {
            if !val {
                let context = DecodingError.Context(codingPath: container.codingPath, debugDescription: "Cannot pass false for Senders")
                throw DecodingError.dataCorrupted(context)
            }
            self = .allowAll(val: val)
        } else {
            self = .allowSome(val: try container.decode([String:SenderEnum].self))
        }
    }
}

struct _AuditTable: Decodable {
    var senders: AllSendersEnum
    enum CodingKeys: String, CodingKey {
        case senders = "Senders"
    }
}

/// Defines what logs splunkloggingd is allowed to forward
final class AuditTable: Sendable {
    let table: _AuditTable
    
    init(at path: URL) throws {
        log.log("Creating audit table at path: \(path.path(percentEncoded: false), privacy: .public)")
        let data = try Data(contentsOf: path)
        let decoder = PropertyListDecoder()

        table = try decoder.decode(_AuditTable.self, from: data)
    }

    private func getSenderEnum(forEvent event: OSLogEventProxyProtocol) -> SenderEnum? {
        switch table.senders {
        case .allowAll(_):
            return nil
        case .allowSome(let allTableSenders):
            guard let eventSender = event.sender,
                  let tableSender = allTableSenders[eventSender]
            else {
                return nil
            }

            return tableSender
        }
    }

    private func getSenderData(fromSenderEnum senderEnum: SenderEnum) -> SenderData? {
        switch senderEnum {
        case .allowAll(_):
            return nil
        case .allowSome(let val):
            return val
        }
    }

    private func getAuditState(fromSenderData senderData: SenderData, forEvent event: OSLogEventProxyProtocol) -> AuditState {
        // If the event is malformed and doesn't have the format string set, default to Denied and drop it
        guard let eventFormatString = event.formatString else {
            return .Denied
        }

        // A string not in the table has never never been audited
        guard let tableFormatString = senderData.formatStrings[eventFormatString] else {
            return .UnAudited
        }

        return tableFormatString.state
    }

    private func allLogsBlanketAllowed() -> Bool {
        // Top level of Senders key can be true (allow all), or a dict of senders
        switch table.senders {
        case .allowAll(let val):
            return val
        case .allowSome(_):
            return false
        }
    }

    private func senderBlanketAllowed(forSenderEnum senderEnum: SenderEnum) -> Bool {
        // Each sender in the table can be true (allow all msg from this sender) or a dict with format strings / other data
        switch senderEnum {
        case .allowAll(let val):
            return val
        case .allowSome(_):
            return false
        }
    }

    private func eventMatchesSubsystemEnum(forEvent event: OSLogEventProxyProtocol,
                                           forSubsystemMapping subsystemMapping: [String:SubsystemEnum]) -> Bool {
        guard let eventSubsystem = event.subsystem else {
            return false
        }

        // Check for both the event's explicit subsystem and the wildcard subsystem (i.e. any subsystem, specific cat)
        for sub in [eventSubsystem, "*"] {
            guard let subsystemEnum = subsystemMapping[sub] else {
                continue
            }

            switch subsystemEnum {
            // Just subsystem required, category irrelevant
            case .all(let val):
                return val

            // Specific categories required
            case .some(let requiredCategories):
                if let eventCategory = event.category,
                   requiredCategories.contains(eventCategory)
                {
                    return true
                }
            }
        }

        return false
    }

    private func eventPassesRequiredSubsystems(forEvent event: OSLogEventProxyProtocol, forSenderData senderData: SenderData) -> Bool {
        // If there are no required subsystems, event passes the requirement
        guard let mapping = senderData.requiredSubsystems else {
            return true
        }

        return self.eventMatchesSubsystemEnum(forEvent: event, forSubsystemMapping: mapping)
    }

    private func subsystemBlanketAllowed(forEvent event: OSLogEventProxyProtocol, forSenderData senderData: SenderData) -> Bool {
        // If there are no blanket allowed subsystems, the event is not blanket allowed
        guard let mapping = senderData.blanketAllowedSubsystems else {
            return false
        }

        return self.eventMatchesSubsystemEnum(forEvent: event, forSubsystemMapping: mapping)
    }

    // Check if the audit table allows a specific event to be forwarded
    func allows(event: OSLogEventProxyProtocol) -> Bool {
        if self.allLogsBlanketAllowed() {
            return true
        }

        // Sender missing from the list
        guard let senderEnum = self.getSenderEnum(forEvent: event) else {
            return false
        }

        if self.senderBlanketAllowed(forSenderEnum: senderEnum) {
            return true
        }

        // This senderEnum is either "always allowed" (above case) or a value (this case). This shouldn't fail, and if it
        // does, we should be conservative and drop the event
        guard let senderData = self.getSenderData(fromSenderEnum: senderEnum) else {
            return false
        }

        if !self.eventPassesRequiredSubsystems(forEvent: event, forSenderData: senderData) {
            return false
        }

        // A string that is explicitly denied by privacy should be rejected, even if that subsystem is blanket allowed
        let auditState = self.getAuditState(fromSenderData: senderData, forEvent: event)
        if auditState == .Denied {
            return false
        }

        if self.subsystemBlanketAllowed(forEvent: event, forSenderData: senderData) {
            return true
        }

        return auditState == .Allowed
    }

    private func formatStringDataForProxy(_ event: OSLogEventProxyProtocol) -> FormatStringData? {
        guard let eventSender = event.sender,
              let eventFormatString = event.formatString else {
            return nil
        }

        let allTableSenders: [String:SenderEnum]
        switch table.senders {
        case .allowAll(_):
            return nil
        case .allowSome(let val):
            allTableSenders = val
        }

        guard let tableSender = allTableSenders[eventSender] else {
            return nil
        }

        let senderData: SenderData
        switch tableSender {
        case .allowAll(_):
            return nil
        case .allowSome(let val):
            senderData = val
        }

        return senderData.formatStrings[eventFormatString]
    }

    // Default to true unless set otherwise in the audit list
    func shouldForwardComposedMessage(forEvent event: OSLogEventProxyProtocol) -> Bool {
        guard let tableFormatString = formatStringDataForProxy(event),
              let shouldDrop = tableFormatString.dropComposedMessage else {
            return true
        }

        // Would be nicer if this were "shouldForward", but more logical for engineers to add "drop this message"
        // to the audit list than "don't forward this message"
        return !shouldDrop
    }

    // If the event has structured data defined in the audit table, create the response json for it
    func structureData(forEvent event: OSLogEventProxyProtocol) -> [String:String]? {
        guard let tableFormatString = formatStringDataForProxy(event),
              let argNames = tableFormatString.argNames else {
            return nil
        }

        // At this point, we have both a decomposed message and requested arg names. We need to stitch them together
        let minLen: Int = min(argNames.count, event.argCount)
        var result: [String:String] = [:]
        for i in 0..<minLen {
            // Unfortunately the 2 indexing schemes use different types (Int vs Uint)...
            let name = argNames[Int(i)]
            guard let val = event.stringifiedArg(atIndex: i) else {
                return nil
            }

            result[name] = val
        }

        return result
    }
}
