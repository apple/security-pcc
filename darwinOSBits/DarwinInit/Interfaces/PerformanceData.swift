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
//  PerformanceData.swift
//  darwin-init
//

import Foundation
import os
import perfdata
import System
import DarwinPrivate.libproc

enum PerformanceData {
    /// Write perfdata to `/tmp/pdstats`
    ///
    /// - Parameter filename: The name of the file to store the json
    /// - Returns: `true` for success, `false` for failure
    ///
    /// Creates a perfdata JSON file and places it at /tmp/pdstats. This is intended as a snapshot of the
    /// initial boot of a system. Time to boot, footprint and wired memory (aka dirty) as well as the number
    /// of processes and the amount of disk used.
    static func writeStats(to path: FilePath) -> Bool {
        autoreleasepool {

            // get the time since boot (since we are early in the boot uptime is a good estimate. (we do this before
            // running the footprint command since it is relatively expensive.
            let uptime = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / Double(NSEC_PER_SEC)

            // get the total dirty. This is a rather heavyweight process. We run the footprint command and then crack the
            // json extracting the single value `total footprint`.

            // run the command
            let outPath = FilePath("/private/var/tmp/footprint.json")
            let command = "/usr/bin/footprint -a --vmObjectDirty -j \(outPath)"

            guard Subprocess.run(shell: nil, command: command, savingStandardOutTo: "/dev/null") else {
                return false
            }

            // get the data into a buffer and remove the file.
            let stdoutData: Data
            do {
                stdoutData = try outPath.loadData()
            } catch {
                logger.error("Read of footprint stdout failed, \(error.localizedDescription)")
                return false
            }

            do {
                try outPath.remove()
            } catch {
                logger.error("Unable to delete the footprint.json, \(error.localizedDescription)")
            }

            // crack the json
            let json: NSDictionary
            do {
                json = try JSONSerialization.jsonObject(with: stdoutData, options: .mutableContainers) as! NSDictionary
            } catch  {
                logger.error("Parse of footprint failed, \(error.localizedDescription)")
                return false
            }

            // get the integer value of `total footprint`
            guard let total = json["total footprint"] as? Int else {
                logger.error(#"Parse of footprint failed to find "total footprint""#)
                return false
            }

            // FIXME: replace with __proc_info
            // get the estimate of the number of pids. (this is the number of pids padded by 20)
            var numPids = proc_listallpids(nil, 0)
            guard numPids > 0 else {
                logger.error("Unable to list all pids, \(errno)")
                return false
            }

            // get the list of pids which seems like the only reliable method to get the actual count.
            let bytes = Int(numPids) * MemoryLayout<pid_t>.stride
            let pids = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: MemoryLayout<pid_t>.alignment)
            defer { pids.deallocate() }
            numPids = proc_listallpids(UnsafeMutableRawPointer(pids), Int32(bytes))
            guard numPids > 0 else {
                logger.error("Unable to list all pids, \(errno)")
                return false
            }

            // get the total used disk space in the / filesystem
            var stat = statfs()
            guard statfs("/", &stat) == 0 else {
                logger.error("Unable to statfs /, \(errno)")
                return false
            }
            let used = UInt64(stat.f_bsize) * (stat.f_blocks - stat.f_bfree)

            // Create the json file.
            guard let wr = pdwriter_open(path.description, "darwinOSBits.DarwinOSBoot", 1, 0) else {
                logger.error("Unable to open pdwriter, \(errno)")
                return false
            }

            pdwriter_new_value(wr, "dirty_memory", pdunit_bytes, Double(total))
            "processes".withCString { ptr in
                // This is very sketchy, but required because `pdwriter_new_value` takes
                // the unit string as a `void*`
                let mut = UnsafeMutableRawPointer(mutating: ptr)
                pdwriter_new_value(wr, "#processes", mut, Double(numPids))
            }
            pdwriter_new_value(wr, "boot_time", pdunit_seconds, Double(uptime))
            pdwriter_new_value(wr, "disk_used", pdunit_bytes, Double(used))
            pdwriter_close(wr)
            logger.log("PD Stats written to \(path)")

            return true
        }
    }
}
