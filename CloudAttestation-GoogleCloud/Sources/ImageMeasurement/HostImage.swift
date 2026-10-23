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
//  HostImage.swift
//  CloudAttestationV2
//
//  Copyright © 2026 Apple Inc. All rights reserved.
//

import Common
import Crypto
import Foundation

public struct HostImage: Sendable {
    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    public func measure() throws -> HostImageMeasurements {
        let imageData = try Data(contentsOf: url, options: .mappedIfSafe)
        let disk = try GPT.Disk(imageData: imageData)

        let efiData = try disk.partitionData(label: "EFI-SYSTEM")
        let oemData = try disk.partitionData(label: "OEM")
        let oemFS = try Ext4.FileSystem(partitionData: oemData)

        let hostUKIDigest = try ukiDigest(efiPartitionData: efiData, using: SHA256.self)
        let ovmfDigest = try measureOVMF(oemFS: oemFS)

        // The driver lives inside the workload guest VM, not on the host OEM partition. Open
        // the workload qcow2 once and reuse its disk for both the UKI digest and the driver.
        let workloadDisk = try openGuestDisk(oemFS: oemFS, filename: "workload_vm_image.qcow2")
        let workloadEFI = try workloadDisk.partitionData(label: "EFI-SYSTEM")
        let workloadUKIDigest = try ukiDigest(efiPartitionData: workloadEFI, using: SHA384.self)

        let workloadRootData = try workloadDisk.partitionData(label: "ROOT-A")
        let workloadRoot = try Ext4.FileSystem(partitionData: workloadRootData)
        let installedDriverVersions = (try? workloadRoot.listDirectory(at: "/opt/nvidia")) ?? []
        guard installedDriverVersions.count == 1, let nvidiaDriverVersion = installedDriverVersions.first else {
            throw ImageMeasurementError.invalidImageFile(
                "Expected exactly one NVIDIA driver under /opt/nvidia in workload guest VM, found \(installedDriverVersions)"
            )
        }

        let keyProtectionDisk = try openGuestDisk(oemFS: oemFS, filename: "key_oracle_vm_image.qcow2")
        let keyProtectionEFI = try keyProtectionDisk.partitionData(label: "EFI-SYSTEM")
        let keyProtectionUKIDigest = try ukiDigest(efiPartitionData: keyProtectionEFI, using: SHA384.self)

        return HostImageMeasurements(
            hostUKIDigest: hostUKIDigest,
            workloadUKIDigest: workloadUKIDigest,
            workloadOVMFDigest: ovmfDigest,
            keyProtectionUKIDigest: keyProtectionUKIDigest,
            keyProtectionOVMFDigest: ovmfDigest,
            nvidiaDriverVersion: nvidiaDriverVersion
        )
    }

    /// Digests the UKI PE image (sans signature) at `/EFI/BOOT/bootx64.efi`.
    ///
    /// The hash algorithm mirrors the register the image is measured into at runtime: the guest
    /// VM UKIs land in TDX SHA-384 RTMRs, while the bare-metal host UKI lands in the host TPM's
    /// SHA-256 PCR[21]. Callers must pass the matching `hasher` so the derived digest reconciles
    /// with the attestation-time projection in ``ReleaseV2/workload(bundle:claims:)``.
    private func ukiDigest<Hash: HashFunction>(efiPartitionData: Data, using hasher: Hash.Type) throws -> Data {
        let fs = try FAT.FileSystem(partitionData: efiPartitionData)
        let ukiData = try fs.readFile(at: "/EFI/BOOT/bootx64.efi")
        let pe = try PE.File(fileData: ukiData)
        return Data(pe.digest(using: hasher))
    }

    private func measureOVMF(oemFS: Ext4.FileSystem) throws -> Data {
        let ovmfData = try oemFS.readFile(at: "/tdx-qemu-app/usr/share/ovmf/OVMF.inteltdx.fd")
        return try OVMFFirmware(data: ovmfData).mrtd
    }

    private func openGuestDisk(oemFS: Ext4.FileSystem, filename: String) throws -> GPT.Disk<Qcow2.Disk<Ext4.FileHandle>> {
        let qcow2File = try oemFS.openFile(at: "/\(filename)")
        let qcow2Disk = try Qcow2.Disk(storage: qcow2File)
        return try GPT.Disk(image: qcow2Disk)
    }
}

public struct HostImageMeasurements: Sendable {
    public let hostUKIDigest: Data
    public let workloadUKIDigest: Data
    public let workloadOVMFDigest: Data
    public let keyProtectionUKIDigest: Data
    public let keyProtectionOVMFDigest: Data
    public let nvidiaDriverVersion: String

    public init(
        hostUKIDigest: Data,
        workloadUKIDigest: Data,
        workloadOVMFDigest: Data,
        keyProtectionUKIDigest: Data,
        keyProtectionOVMFDigest: Data,
        nvidiaDriverVersion: String
    ) {
        self.hostUKIDigest = hostUKIDigest
        self.workloadUKIDigest = workloadUKIDigest
        self.workloadOVMFDigest = workloadOVMFDigest
        self.keyProtectionUKIDigest = keyProtectionUKIDigest
        self.keyProtectionOVMFDigest = keyProtectionOVMFDigest
        self.nvidiaDriverVersion = nvidiaDriverVersion
    }
}
