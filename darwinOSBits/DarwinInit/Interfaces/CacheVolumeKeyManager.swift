// Copyright © 2025 Apple Inc. All Rights Reserved.

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
//  CacheVolumeKeyManager.swift
//  DarwinInit
//
//

import Foundation
import LocalAuthenticationCredentialServices
import System
import APFS
import AppleKeyStore
internal import DarwinInitBridging

extension Data {
    enum AKSDataError: Swift.Error {
        case emptyData
    }

    mutating func withUnsafeMutableAKSData<T>(
        aks_fv_data : inout aks_fv_data_s, body: (inout aks_fv_data_s) -> T
    ) -> T {
        self.withUnsafeMutableBytes { dataBuffer in
            aks_fv_data.data = dataBuffer.baseAddress
            aks_fv_data.len = dataBuffer.count
            return body(&aks_fv_data)
        }
    }

    init(aks_data: aks_fv_data_s) throws {
        logger.debug("Attempting to initialze Data from aks_fv_data_s with length: \(aks_data.len)")
        guard let data = aks_data.data, aks_data.len != 0 else {
            throw AKSDataError.emptyData
        }
        self.init(bytes: data, count: aks_data.len)
    }
}

enum CacheVolumeKeyManagerError: Error {
    case setupFailure(UUID, Swift.Error)
    case AKS_FV_Failure(AKSFilevaultOperation, String)
    case keyCachingFailure(Swift.Error)
    case missingKeyFiles(UUID)
    case keyDeletionFailure(UUID, Swift.Error)
    case missingKeyData(UUID)
    case APFSKeyPlumbingError(UUID, Int32)
    case missingLACSSecurePassword
}

extension CacheVolumeKeyManagerError: CustomStringConvertible {
    var description: String {
        switch self {
        case .setupFailure(let uuid, let error):
            return "Failed to initialize keys cache for volume \(uuid): \(error.localizedDescription)"
        case .missingKeyFiles(let uuid):
            return "Unexpectedly missing WKEK and WVEK cache files for existing volume \(uuid)"
        case .missingKeyData(let uuid):
            return "WKEK and WVEK cache files for volume \(uuid) exist but contain no data"
        case .AKS_FV_Failure(let operation, let reason):
            return "AKS Filevault operation \(operation.description) failed due to \(reason)"
        case .APFSKeyPlumbingError(let uuid, let error):
            return "Passing keys for volume \(uuid) to APFS failed with error: \(error)"
        case .keyCachingFailure(let error):
            return "Failed to cache new WKEK and WVEK: \(error.localizedDescription)"
        case .missingLACSSecurePassword:
            return "LACSSecurePassword for secret is nil, secret was not stored properly"
        case .keyDeletionFailure(let uuid, let error):
            return "Failed to fully purge WKEK and WVEK cache directory for volume \(uuid): \(error.localizedDescription)"
        
        }
    }
}

enum AKSFilevaultOperation {
    case newKEK
    case newVEK
    case loadKeys
    case unloadKeys
}

extension AKSFilevaultOperation: CustomStringConvertible {
    var description: String {
        switch self {
        case .newKEK:
            return "aks_fv_new_kek"
        case .newVEK:
            return "aks_fv_new_vek"
        case .loadKeys:
            return "aks_fv_prot_cmd_load_volume_keys"
        case .unloadKeys:
            return "aks_fv_prot_cmd_unload_volume_keys"
        }
    }
}

@available(macOS 16.0, iOS 19.0, *)
public class CacheVolumeKeyManager {
    var uuid: UUID
    var secPassword: LACSSecurePassword?
    var wkek: Data
    var wvek: Data

    // Mutable vars for testing
    var keysCacheRootDirectory: FilePath = kCacheVolumeKeyCacheRootDirectory
    var uniqueKeysCacheDirectory: FilePath {
        return keysCacheRootDirectory.appending(self.uuid.uuidString)
    }
    var wkekCacheFile: FilePath {
        return self.uniqueKeysCacheDirectory.appending("wkek")
    }
    var wvekCacheFile: FilePath {
        return self.uniqueKeysCacheDirectory.appending("wvek")
    }

    public init(forExistingVolumeWith uuid: UUID, secret: Data) throws {
        self.uuid = uuid
        self.wkek = Data()
        self.wvek = Data()

        // Store secret in SEP using LACSSecurePassword and keep instance alive!
        self.secPassword = try LACSSecurePassword(data: secret)

        // Fetch existing keys from Preboot
        try fetchKeys()
    }

    public init(forNewVolumeWith uuid: UUID, secret: Data) throws {
        self.uuid = uuid
        self.wkek = Data()
        self.wvek = Data()

        // Store secret in SEP using LACSSecurePassword and keep instance alive!
        self.secPassword = try LACSSecurePassword(data: secret)
        // Create new wkek and wvek with that secret
        try createKeys()

        try cacheKeys(wkek_blob: self.wkek, wvek_blob: self.wvek)
    }

    public init(forOrphanedVolumeWith uuid: UUID) {
        self.uuid = uuid
        self.wkek = Data()
        self.wvek = Data()
        self.secPassword = nil
    }

    func initUniqueKeysCache() throws {
        // Note: this will succeed if the cache dir already exists
        do {
            try self.keysCacheRootDirectory.createDirectory(permissions: .ownerReadWriteExecute, intermediateDirectories: true)
            try self.uniqueKeysCacheDirectory.createDirectory(permissions: .ownerReadWriteExecute, intermediateDirectories: true)
        } catch {
            throw CacheVolumeKeyManagerError.setupFailure(self.uuid, error)
        }
    }

    private func cacheKeys(wkek_blob: Data, wvek_blob: Data) throws {
        // Create keys cache directory if not already set up, cache keys!
        try initUniqueKeysCache()

        do {
            logger.info("Attempting to cache WKEK blob...")
            try wkek_blob.write(to: URL(filePath: self.wkekCacheFile.string))
        } catch {
            throw CacheVolumeKeyManagerError.keyCachingFailure(error)
        }
        logger.info("Successfully cached WKEK to \(self.wkekCacheFile.string)")

        do {
            logger.info("Attempting to cache WVEK blob...")
            try wvek_blob.write(to: URL(filePath: self.wvekCacheFile.string))
        } catch {
            throw CacheVolumeKeyManagerError.keyCachingFailure(error)
        }
        logger.info("Successfully cached WVEK to \(self.wvekCacheFile.string)")
    }

    private func fetchKeys() throws {
        // Ensure that wkek and wvek cache files exist as expected
        guard try wkekCacheFile.fileExists() && wvekCacheFile.fileExists() else {
            throw CacheVolumeKeyManagerError.missingKeyFiles(self.uuid)
        }

        // Read wkek and wvek data out of their respective files
        let wkek_blob = try Data(contentsOf: URL(filePath: self.wkekCacheFile.string))
        let wvek_blob = try Data(contentsOf: URL(filePath: self.wvekCacheFile.string))
        guard !wkek_blob.isEmpty && !wvek_blob.isEmpty else {
            throw CacheVolumeKeyManagerError.missingKeyData(self.uuid)
        }
        logger.info("Successfully loaded WKEK and WVEK for volume \(self.uuid) from cache")

        self.wkek = wkek_blob
        self.wvek = wvek_blob
    }

    func deleteKeys() throws {
        // Remove entire keys cache directory for this uuid, including wkek, wvek, any potential junk
        logger.info("Deleting cached keys for volume \(self.uuid)...")
        do {
            try self.uniqueKeysCacheDirectory.removeAllFilesInDirectory()
        } catch {
            throw CacheVolumeKeyManagerError.keyDeletionFailure(self.uuid, error)
        }

        do {
            try self.uniqueKeysCacheDirectory.removeEmptyDirectory()
        } catch {
            logger.info("Attempted to delete empty \(self.uniqueKeysCacheDirectory.string) but failed: \(error)")
        }

        // If the CacheVolumeKeys directory in Preboot happens to be empty, delete it out too
        do {
            if try self.keysCacheRootDirectory.isEmptyDirectory() {
                try self.keysCacheRootDirectory.removeEmptyDirectory()
            }
        } catch {
            logger.error("Attempted to delete empty \(kCacheVolumeKeyCacheRootDirectory) but failed: \(error)")
        }
    }

    /// Loads volume keys via `aks_fv_prot_cmd_load_volume_keys`, meant to be called after unlock and before mount to support class keys
    func loadVolumeKeys() throws {
        guard let secPassword = self.secPassword else {
            throw CacheVolumeKeyManagerError.missingLACSSecurePassword
        }
        // Use the externalized ACMContextRef to the secret to minimize handling of raw secret
        var secretRef = secPassword.contextRef()
        var aks_secret = aks_fv_data_s()

        var params = aks_fv_param_s()
        // Specify that the secret used to wrap KEK is an externalized ACMContextRef
        params.options = aks_fv_params_option_t(aks_fv_params_option_secret_is_acm)

        let cmd : aks_fv_prot_cmd_t = aks_fv_prot_cmd_t(aks_fv_prot_cmd_load_volume_keys)

        let options: aks_fv_prot_opts_t = aks_fv_prot_opts_t(aks_fv_prot_opts_none)

        var aks_wkek = aks_fv_data_s()
        var aks_wvek = aks_fv_data_s()

        let status = secretRef.withUnsafeMutableAKSData(aks_fv_data: &aks_secret) { secretRefBuffer in
            return self.wkek.withUnsafeMutableAKSData(aks_fv_data: &aks_wkek) { wkekRefBuffer in
                return self.wvek.withUnsafeMutableAKSData(aks_fv_data: &aks_wvek) { wvekRefBuffer in
                    return aks_fv_set_protection(
                        &params,
                        cmd,
                        options,
                        &secretRefBuffer,
                        &wkekRefBuffer,
                        &wvekRefBuffer,
                        nil
                    )
                }
                
            }
        }

        guard status == 0 else {
            throw CacheVolumeKeyManagerError.AKS_FV_Failure(AKSFilevaultOperation.loadKeys, "AKS error code \(String(format: "%x", status))")
        }

        logger.info("Successfully loaded volume keys for volume \(self.uuid)")
    }

    /// Loads volume keys via `aks_fv_prot_cmd_unload_volume_keys`, meant to be called after unlock and before mount to support class keys
    func unloadVolumeKeys() throws {
        // Fetch existing keys from Preboot so we can unload
        try fetchKeys()

        var params = aks_fv_param_s()
        params.options = aks_fv_params_option_t(aks_fv_params_option_none)

        let cmd : aks_fv_prot_cmd_t = aks_fv_prot_cmd_t(aks_fv_prot_cmd_unload_volume_keys)

        let options: aks_fv_prot_opts_t = aks_fv_prot_opts_t(aks_fv_prot_opts_none)

        var aks_wvek = aks_fv_data_s()

        let status = self.wvek.withUnsafeMutableAKSData(aks_fv_data: &aks_wvek) { wvekRefBuffer in
            return aks_fv_set_protection(
                &params,
                cmd,
                options,
                nil,
                nil,
                &wvekRefBuffer,
                nil
            )
        }

        /* If the volume has already been unmounted from a reboot AKS will fail to unload keybag from internal list with kAKSReturnNotFound.
         In this case we don't care that unloading keys failed */
        guard status == 0 || status == kAKSReturnNotFound else {
            throw CacheVolumeKeyManagerError.AKS_FV_Failure(AKSFilevaultOperation.unloadKeys, "AKS error code \(String(format: "%x", status))")
        }

        logger.info("Successfully unloaded volume keys for volume \(self.uuid)")
    }

    func unlock(disk: UnsafePointer<CChar>) throws {
        guard let secPassword = self.secPassword else {
            throw CacheVolumeKeyManagerError.missingLACSSecurePassword
        }
        let secretRef = secPassword.contextRef()
        var uuidTuple = self.uuid.uuid

        let status = withUnsafeMutableBytes(of: &uuidTuple) { uuidBuffer in
            return APFSVolumeCacheKey(disk, uuidBuffer.baseAddress, self.wkek as CFData, self.wvek as CFData, secretRef as CFData, apfs_fv_options_t(apfs_fv_options_secret_is_acm))
        }

        // Ensure passing keys to APFS succeeded with no errors or APFS already has keys cached (indicated by EEXIST)
        guard status == 0 || status == EEXIST else {
            throw CacheVolumeKeyManagerError.APFSKeyPlumbingError(self.uuid, status)
        }
        logger.info("Successfully unlocked volume \(self.uuid)")
    }

    /// Generates a new wrapped KEK and VEK using the secret for this volume uuid
    func createKeys() throws {
        guard let secPassword = self.secPassword else {
            throw CacheVolumeKeyManagerError.missingLACSSecurePassword
        }
        // Use the externalized ACMContextRef to the secret to minimize handling of raw secret
        var secretRef = secPassword.contextRef()
        var aks_secret = aks_fv_data_s()
        var params = aks_fv_param_s()
        // Specify that the secret used to create wkek is an externalized ACMContextRef
        params.options = aks_fv_params_option_t(aks_fv_params_option_secret_is_acm)

        let options: aks_fv_options_t = aks_fv_options_t(aks_fv_options_cache_volume)

        var wkek_size : size_t = 0
        aks_fv_get_size(&params, aks_fv_type_t(aks_fv_type_kek), &wkek_size)
        var wkek_data = Data(count: wkek_size)
        var wkek = aks_fv_data_s()

        var status = secretRef.withUnsafeMutableAKSData(aks_fv_data: &aks_secret) { secretRefBuffer in
            return wkek_data.withUnsafeMutableAKSData(aks_fv_data: &wkek) { wkekDataBuffer in
                return withUnsafeBytes(of: uuid.uuid) { uuidBuffer in
                    aks_fv_new_kek(
                        &params,
                        options,
                        &secretRefBuffer,
                        uuidBuffer.baseAddress,
                        &wkekDataBuffer
                    )
                }
            }
        }
        guard status == 0 else {
            throw CacheVolumeKeyManagerError.AKS_FV_Failure(AKSFilevaultOperation.newKEK,"AKS error code \(String(format: "%x", status))")
        }
        // Do a preliminary check that new wkek actually has data before bothering with wvek generation
        guard wkek.data != nil else {
            throw CacheVolumeKeyManagerError.AKS_FV_Failure(AKSFilevaultOperation.newKEK, "New WKEK generation succeeded, but WKEK data is nil")
        }

        // zero out params in case modified by aks_fv_new_kek
        params = aks_fv_param_s()
        // Specify that the secret used to create wkek is an externalized ACMContextRef
        params.options = aks_fv_params_option_t(aks_fv_params_option_secret_is_acm)

        var wvek_size : size_t = 0
        aks_fv_get_size(&params, aks_fv_type_t(aks_fv_type_vek), &wvek_size)
        var wvek_data = Data(count: wvek_size)
        var wvek = aks_fv_data_s()

        status = secretRef.withUnsafeMutableAKSData(aks_fv_data: &aks_secret) { secretRefBuffer in
            return wvek_data.withUnsafeMutableAKSData(aks_fv_data: &wvek) { wvekDataBuffer in
                return withUnsafeBytes(of: uuid.uuid) { uuidBuffer in
                    aks_fv_new_vek(
                        &params,
                        &secretRefBuffer,
                        &wkek,
                        uuidBuffer.baseAddress,
                        &wvekDataBuffer,
                        nil
                    )
                }
            }
        }
        guard status == 0 else {
            throw CacheVolumeKeyManagerError.AKS_FV_Failure(AKSFilevaultOperation.newVEK,"AKS error code \(String(format: "%x", status))")
        }

        // Save wkek and wvek as Data, only upon successful conversion do we declare success
        self.wkek = try Data(aks_data: wkek)
        logger.log("Successfully generated new WKEK and converted to Data for volume \(self.uuid)")
        self.wvek = try Data(aks_data: wvek)
        logger.log("Successfully generated new WVEK and converted to Data for volume \(self.uuid)")
    }
}
