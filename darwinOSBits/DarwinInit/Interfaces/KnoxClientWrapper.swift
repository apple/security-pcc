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
//  KnoxClient.swift
//  DarwinInit
//

import Foundation
import KnoxClientPublic
import System
import CryptoKit
import libnarrativecert
import os

enum KnoxClientWrapper {
    static let logger = Logger.knoxClient
    
    private static func getWestgateToken(wgUsername: String, wgToken: String) -> WestgateToken? {
        do {
            let tokenJSON = try JSONEncoder().encode(["Username":"\(wgUsername)",
                                                      "Password":"\(wgToken)"])
            let westgateToken = try JSONDecoder().decode(WestgateToken.self, from: tokenJSON)
            return westgateToken
        } catch {
            logger.error("Failed to decode WestgateToken from credentials: \(error)")
        }
        return nil
    }
    
    static func getKnoxServiceClient(authentication: DownloadAuthentication, knoxServerURL: URL, altCDN: String?, retries: UInt?) -> KnoxServiceClient? {
        let knoxClient: KnoxServiceClient
        switch authentication {
            case .oidc(let token):
                let oidc_token = OIDCToken(token: token)
                logger.log("OIDC token present, using OIDC to authenticate with Knox.")
                knoxClient = KnoxServiceClient(authToken: oidc_token, delegate: KnoxClientDelegate(), knoxHostURL: knoxServerURL)
            case .daw(_):
                logger.log("DAW tokens are deprecated. Cannot initialize KnoxServiceClient. Please use mTLS, Westgate, or OIDC.")
                return nil
                
            case .westgate(let username, let token):
                logger.log("Westgate token and username present, using Westgate token to authenticate with Knox.")
                guard let westgateToken = getWestgateToken(wgUsername: username, wgToken: token) else {
                    return nil
                }
                knoxClient = KnoxServiceClient(westgateToken: westgateToken, delegate: KnoxClientDelegate(), knoxHostURL: knoxServerURL)
                
            case .none:
                logger.log("DAW token not present, using narrative cert to authenticate to knox.")
                // First we check for an aquaria-host cert, then fall back to acdc-actor
                var cert = NarrativeCert(domain: .aquaria, identityType: .host)
                var credential = cert.getCredential()
                if credential != nil {
                    logger.log("Successfully created aquaria-host url credential for knox auth.")
                } else {
                    cert = NarrativeCert(domain: .acdc, identityType: .actor)
                    credential = cert.getCredential()
                    if credential != nil {
                        logger.log("Successfully created acdc-actor url credential for knox auth.")
                    }
                }

                guard let credential else {
                    logger.error("Error getting URLCredential for narrative certificate.")
                    return nil
                }

                let mtlsAuth = mTLSAuth(urlCredential: credential)
                knoxClient = KnoxServiceClient(knoxMtlsAuth: mtlsAuth, SAKSmTLSAuth: mtlsAuth, delegate: KnoxClientDelegate() , knoxHostURL: knoxServerURL)
        }
        // Override CDN host url to specified alternative instead of knox.cdn-apple.com
        if let altCDN {
            knoxClient.alternateCDNHost = altCDN
        }
        // Configure the number of retries for network failures with backoff
        if let retries {
            knoxClient.networkOperationTryCount = retries
            knoxClient.useExponentialRetryDelay = true
        }
        return knoxClient
    }
    
    // Download a raw, encrypted asset from Knox to a specified directory path
    static func downloadRaw(from url: URL,
                            to destinationDirectory: FilePath? = nil,
                            configuration: DownloadConfiguration = DownloadConfiguration(),
                            authentication: DownloadAuthentication,
                            alternateCDNHost: String? = nil) async -> FilePath? {
		guard let destinationDirectory = destinationDirectory ?? FilePath.createTemporaryDirectory() else {
			return nil
		}

        // Parse Knox URL of the form: knox://$HOST/download/$SPACE/$DIGEST#name=$FILENAME
        let (gotURL, gotSpace, gotDigest, gotOutputFilename) = parseDownloadURL(url.absoluteString, outputFile: nil) ?? (nil, nil, nil, nil)
        guard let digest = gotDigest,
              let knoxServerURL = gotURL,
              let space = gotSpace,
              let downloadName = gotOutputFilename else {
            logger.error("Failed to parse Knox url: \(url.absoluteString, privacy: .public)")
            return nil
        }
        
        guard let knoxClient = getKnoxServiceClient(authentication: authentication, knoxServerURL: knoxServerURL, altCDN: alternateCDNHost, retries: configuration.downloadRetries) else {
            logger.error("Failed to initialize KnoxServiceClient to download \(url.absoluteString)")
            return nil
        }
        
        // Set up download file path for cryptex from Knox
        // TODO: downloadName is optional, so should also support this
		let knoxDestinationPath = destinationDirectory.appending(downloadName)
        guard let destinationPathURL = URL(filePath: knoxDestinationPath) else {
            logger.error("Failed to create directory for Knox download")
            return nil
        }
        
        let file = KnoxPointer.File(digest: digest)
        var pointer: KnoxPointer
        do {
            pointer = try GenericFilePointer(file: file,
                                             knoxServer: knoxServerURL,
                                             name: downloadName,
                                             /*permissions: KnoxPointer.Permissions(),*/
                                             space: space)
        } catch {
            logger.error("Could not obtain Knox pointer to \(url.absoluteString, privacy: .public)")
            return nil
        }
        logger.info("Created a GenericFilePointer to \(url.absoluteString) with knoxServerURL: \(knoxServerURL)")
        
        // Download the raw, encrypted knox asset
        logger.info("Downloading encrypted cryptex from \(url.absoluteString) to \(knoxDestinationPath.description)")
        
        let enableBackground = configuration.networkServiceType == .background
        logger.info("Using \(enableBackground ? "background" : "default") traffic class.")
        
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) -> Void in
                let _ = knoxClient.download(pointer, destination: destinationPathURL, networkServiceType: (enableBackground ? .background : .default), downloadType: .raw) {
                    maybeError in
                    if let maybeError {
                        if let kscError = maybeError as? KnoxServiceClient.ClientError {
                            logger.error("Encountered error when downloading from knox: \(kscError.localizedDescription, privacy: .public)\n")
                            continuation.resume(throwing: kscError)
                        } else {
                            logger.error("Encountered error when downloading from knox: \(String(describing: maybeError), privacy: .public)\n")
                            continuation.resume(throwing: maybeError)
                        }
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            logger.error("Failed to download knox asset from \(url.absoluteString, privacy: .public) to \(knoxDestinationPath.description): \(error)")
            return nil
        }
        logger.info("Downloaded encrypted cryptex without errors to \(knoxDestinationPath.description)!")
        return knoxDestinationPath
    }
    
    // Fetch the decryption key for Knox asset
    static func getDecryptionComponents(for url: URL,
                                        configuration: DownloadConfiguration = DownloadConfiguration(),
                                        authentication: DownloadAuthentication,
                                        alternateCDNHost: String? = nil) async -> ImageDecryptionComponents? {
        // Parse Knox URL of the form: knox://$HOST/download/$SPACE/$DIGEST#name=$FILENAME
        let (gotURL, gotSpace, gotDigest, _) = parseDownloadURL(url.absoluteString, outputFile: nil) ?? (nil, nil, nil, nil)
        guard let digest = gotDigest,
              let knoxServerURL = gotURL,
              let space = gotSpace else {
            logger.error("Failed to parse Knox url: \(url.absoluteString, privacy: .public)")
            return nil
        }
        
        guard let knoxClient = getKnoxServiceClient(authentication: authentication, knoxServerURL: knoxServerURL, altCDN: alternateCDNHost, retries: configuration.downloadRetries) else {
            logger.error("Failed to initialize KnoxServiceClient to fetch decryption key for \(url.absoluteString)")
            return nil
        }
        
        // Fetch decryption components for the raw, encrypted knox asset
        var gotDecryptionInfo:ImageDecryptionComponents?
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) -> Void in
                let _ = knoxClient.decryptionInfo(digest: digest, inSpace: space)
                { (decryptionInfo, maybeError) in
                    if let maybeError {
                        if let kscError = maybeError as? KnoxServiceClient.ClientError {
                            logger.error("Encountered error when fetching decryption components from knox: \(kscError.localizedDescription, privacy: .public)\n")
                            continuation.resume(throwing: kscError)
                        } else {
                            logger.error("Encountered error when fetching decryption components from knox: \(String(describing: maybeError), privacy: .public)\n")
                            continuation.resume(throwing: maybeError)
                        }
                    } else {
                        gotDecryptionInfo = decryptionInfo
                        continuation.resume()
                    }
                }
            }
        } catch {
            logger.error("Failed to fetch decryption components for Knox asset")
            return nil
        }
        guard let info = gotDecryptionInfo else {
            logger.error("Failed to fetch decryption components for Knox asset")
            return nil
        }

        logger.info("Successfully fetched decryption components for Knox asset")
        return info
    }

    static func getDecryptionKey(from decryptionComponents: ImageDecryptionComponents) -> SymmetricKey? {
		let key = decryptionComponents.encryption.key

		// convert input String key into an array of UInt8 bytes
		guard let hexDecoded = key.hexadecimalASCIIBytes, !hexDecoded.isEmpty else {
			logger.error("Invalid hex decryption key, could not convert to array of UInt8")
			return nil
		}

		// convert array of bytes to SymmetricKey for use in a decryption context
		return SymmetricKey(data: hexDecoded)
	}
    
    
    static func downloadAEADecryptionParameters(for url: URL,
                                                configuration downloadConfiguration: DownloadConfiguration = DownloadConfiguration(),
                                                authentication downloadAuthentication: DownloadAuthentication,
                                                alternateCDNHost: String? = nil) async -> AEADecryptionParameters? {
        guard let decryptionComponents = await KnoxClientWrapper.getDecryptionComponents(for: url,
                                                                                         configuration: downloadConfiguration,
                                                                                         authentication: downloadAuthentication,
                                                                                         alternateCDNHost: alternateCDNHost),
              let key = KnoxClientWrapper.getDecryptionKey(from: decryptionComponents) else {
            return nil
        }
        
        logger.debug("decryption-components.digest-algorithm: \(decryptionComponents.digestAlgorithm)")
        
        if !decryptionComponents.digestAlgorithm.starts(with: "APPLE-ARCHIVE-IDENTIFIER") {
            logger.warning("Decryption components digest doesn't appear to be an Apple Archive identifier!")
        }
        
        guard let archiveIdentifierBytes = decryptionComponents.digest.hexadecimalASCIIBytes, !archiveIdentifierBytes.isEmpty else {
            logger.error("Failed to convert archive identifier from String to Data")
            return nil
        }
        
        return AEADecryptionParameters(
            archiveID: Data(archiveIdentifierBytes),
            decryptionKey: key)
    }
    
    // put actual decryption code in FilePath+AppleArchive?
    
    /// A tuple that stores download URL parse results.
    typealias KnoxDownloadURLParseResult = (serverURL:URL,
                                            space:String,
                                            digest:String,
                                            outputFilename:String)
    
    // TODO: consider making this take in a URL not a string
    static func parseDownloadURL(_ knoxURL:String,
                                 outputFile:String?) -> KnoxDownloadURLParseResult? {
        
        guard let knoxURLComponents = URLComponents(string: knoxURL) else {
            logger.error("Could not get URLComponents from '\(knoxURL, privacy: .public)'")
            return nil
        }
        
        guard knoxURLComponents.scheme?.lowercased() == "knox" else {
            logger.error("URL '\(knoxURL, privacy: .public)' does not have 'knox' scheme")
            return nil
        }
        
        guard let knoxHost = knoxURLComponents.host?.lowercased() else {
            logger.error("Did not find a host in '\(knoxURL, privacy: .public)'")
            return nil
        }
        
        
        var knoxServerURLComponents = URLComponents()
        knoxServerURLComponents.host = knoxHost
        if knoxHost == "localhost" {
            knoxServerURLComponents.scheme = "http"
        }
        else {
            knoxServerURLComponents.scheme = "https"
        }
        knoxServerURLComponents.port = knoxURLComponents.port
        
        guard var knoxServerURL = knoxServerURLComponents.url else {
            logger.error("Could not extract the Knox server URL from '\(String(describing: knoxServerURLComponents.string), privacy: .public)'")
            return nil
        }
        
        let pathComponents = knoxURLComponents.path.components(separatedBy: "/")
        
        guard pathComponents.count >= 4 else {
            logger.error("Could not find space and digest from '\(knoxURL, privacy: .public)' - expected the path to have format: /download/$SPACE/$DIGEST (got: \(pathComponents, privacy: .public))")
            return nil
        }
        
        var space:String?
        var digest:String?
        
        // The first item in the array is an empty string.
        let lastIndex = pathComponents.count - 1
        for i in 1...lastIndex {
            let component = pathComponents[i]
            if (component == "download") && (i + 2 == lastIndex) {
                space = pathComponents[i+1]
                digest = pathComponents[i+2]
                
                // rdar://77399513
                // If there is anything before "download" append it to the server URL
                // For example if the download URI was: knox://localhost/foo/bar/download/sd/3e10
                // then the serverURL should have "localhost/foo/bar"
                let basePath = pathComponents[1..<i].joined(separator: "/")
                // Only append if not empty. See rdar://77409142
                if basePath.count > 0 {
                    knoxServerURL.appendPathComponent(basePath)
                }
                
                break
            }
        }
        
        guard let gotSpace = space,
              let gotDigest = digest,
              gotSpace.count > 0,
              gotDigest.count > 0
        else {
            logger.error("URL '\(knoxURL, privacy: .public)' does not match format '/download/$SPACE/$DIGEST'")
            return nil
        }
        
        var suggestedFileName:String? = nil
        
        if let fragment = knoxURLComponents.fragment {
            if fragment.hasPrefix("name=") {
                suggestedFileName = fragment.components(separatedBy: "=")[1]
            }
        }
        else {
            suggestedFileName = outputFile
        }
        
        let outputFileName = (suggestedFileName ?? gotDigest)
        
        return (knoxServerURL, gotSpace, gotDigest, outputFileName)
    }
    
}

fileprivate class KnoxClientDelegate : KnoxDelegate {
    func task(_ task: KnoxTask, didProgressTo downloadRatio: Float) { }
    func task(_ task: KnoxTask, didCompleteWithError error: Error?) { }
}
