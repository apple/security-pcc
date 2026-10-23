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

//  Copyright © 2024 Apple, Inc. All rights reserved.
//

import Foundation
import Network

// Basic parsing/lookup of system /var/db/dhcpd_leases file used by VZ networking for
//  host/guest communication (NAT and hostOnly). A bridge vif is automatically plumbed
//  when there's at least one VMEnet instance (and torn down with last one).

struct DHCPLeases {
    private let leasesFile: String
    private var leases: [Entry] = []

    private struct Entry {
        var name: String? = nil
        var ip_address: IPAddress? = nil
        var hw_address: String? = nil
        var identifier: String? = nil
        var lease: UInt32 = 0
    }

    init(fromFile: String = "/var/db/dhcpd_leases") throws {
        self.leasesFile = fromFile
        self.leases = try load()
    }

    // lookupIPbyMACAddress returns IP address associated with most recent DHCP lease by mac address;
    //   unfortunately, it's not guaranteed we've picked the correct one in the event the lease exists
    //   across multiple "virtual bridge" subnets that share the same dhcpd instance.
    func lookupIPbyMACAddress(_ macAddr: String) -> IPAddress? {
        let macAddr = depad(macAddr)
        return leases.filter { macAddr == $0.hw_address }
            .sorted(by: { $0.lease > $1.lease })
            .first?.ip_address
    }

    // load reads and parses dhcp leases file as a set of Entry(s)
    private func load() throws -> [Entry] {
        var entries: [Entry] = []

        /*
         {
           ip_address=192.168.64.33
           hw_address=1,12:bb:4d:42:33:7c
           identifier=1,12:bb:4d:42:33:7c
           lease=0x6602725f
         }
         { .. }
         */
        var newEntry: Entry?
        for leaseLine in try String(contentsOfFile: leasesFile, encoding: .utf8).components(separatedBy: "\n") {
            switch leaseLine.trimmingCharacters(in: .whitespaces) {
            case "{":
                newEntry = Entry()

            case "}":
                if let newEntry {
                    entries.append(newEntry)
                }

                newEntry = nil

            case let leaseLine where newEntry != nil:
                let kv = leaseLine.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else {
                    continue
                }

                switch kv[0] {
                case "name": newEntry?.name = String(kv[1])

                case "ip_address":
                    if let ipaddr = IPv4Address(String(kv[1])) {
                        newEntry?.ip_address = ipaddr
                    } else if let ipaddr = IPv6Address(String(kv[1])) {
                        newEntry?.ip_address = ipaddr
                    }

                case "hw_address": newEntry?.hw_address = String(kv[1]).trimPrefix("1,").lowercased()

                case "identifier": newEntry?.identifier = String(kv[1])

                case "lease": newEntry?.lease = UInt32(String(kv[1]).trimPrefix("0x")) ?? 0

                default: continue
                }

            default:
                continue
            }
        }

        return entries
    }

    // depad normalizes difference in whether octets < 16 are 0 padded (VZ == yes; dhcp == no);
    //   e.g. "04:aa:.." -> "4:aa:.."
    private func depad(_ macAddr: String) -> String {
        var macFields = macAddr.components(separatedBy: ":")
        for (i, m) in macFields.enumerated() {
            macFields[i] = String(format: "%x", UInt(m, radix: 16) ?? 0)
        }

        return macFields.joined(separator: ":")
    }
}
