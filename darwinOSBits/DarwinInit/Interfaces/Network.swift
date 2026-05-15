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
//  Network.swift
//  darwin-init
//

import Foundation
import Network
import os
import System
import SystemConfiguration
import Darwin
import DarwinPrivate
import Darwin.POSIX.sys.socket
import libnarrativecert
import CFNetwork_Private.CFNSURLConnection
import RegexBuilder

enum Network {
    static let logger = Logger.network

    // visible for testing
    static var urlSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        return URLSession(configuration: configuration)
    }()

    private class DataDelegate: NSObject, URLSessionTaskDelegate {
        let timeout: TimeInterval?
        public let cred: URLCredential?
        
        public init(timeout t: Duration?, cred: URLCredential?) {
            self.timeout = if let t {
                TimeInterval(t.components.seconds) + Double(t.components.attoseconds)/1e18
            } else {
                nil
            }
            self.cred = cred
        }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            guard let timeout = self.timeout else { return }
            logger.debug("ulrSession.didCreateTask: \(task), setting timeout to \(timeout)")
            task._timeoutIntervalForResource = timeout
        }

        public func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            if (challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate) {
                completionHandler(.useCredential, cred)
            } else {
                completionHandler(.performDefaultHandling, nil);
            }
        }
    }

    private static var narrativeCredential : URLCredential? = {
        // Try to fetch Narrative cert from key chain for authenticated CDN downloads if acdc actor identity configured
        // First we try to use the aquaria-host cert, and if its not available, we fall back to acdc-actor
        var cert = NarrativeCert(domain: .aquaria, identityType: .host)
        var credential = cert.getCredential()
        if credential != nil {
            logger.log("Successfully created aquaria-host url credential for auth challenge")
            return credential
        }

        cert = NarrativeCert(domain: .acdc, identityType: .actor)
        credential = cert.getCredential()
        if credential == nil {
            logger.log("Failed to create URL credential for auth challenge. Narrative identity may not be configured properly.")
        } else {
            logger.log("Successfully created acdc-actor url credential for auth challenge")
        }
        return credential
    }()

    private actor RangeTracker {
        let chunkSize: UInt64
        var currentOffset: UInt64
        
        init(chunkSize: UInt64) {
            self.chunkSize = chunkSize
            self.currentOffset = 0
        }
        
        // Blindly return the next possible range without knowing full content length
        func nextRange() -> ClosedRange<UInt64> {
            let startRange = currentOffset
            let endRange = currentOffset + chunkSize - 1
            // Update offset for next chunk!
            currentOffset += chunkSize
            return startRange...endRange
        }
    }

    private static func writeChunk(to fd: FileDescriptor, data: Data, at offset: Int64) throws {
        let bytesWritten = try data.withUnsafeBytes() {
            try fd.write(toAbsoluteOffset: offset, $0, retryOnInterrupt: true)
        }
        guard bytesWritten == data.count else {
            throw Network.Error.dataTransformFailed(.incomplete("\(bytesWritten) bytes written does not match expected \(data.count)"))
        }
    }

    private static func canDoRangeRequests(for url: URL, chunkSize: UInt64?) async -> Bool {
        // For clients who specify a chunk size, we trust that their server supports range requests
        if let chunkSize {
            logger.info("Range request chunk size of \(chunkSize) specified. Assuming range requests are supported for \(url)")
            return true
        }

        // Otherwise, verify range request support using a HEAD request
        var response : HTTPURLResponse
        do {
            response = try await head(from: url) as HTTPURLResponse
        } catch {
            logger.error("Failed to perfom HEAD request to \(url): \(error)")
            return false
        }

        guard let acceptRanges = response.value(forHTTPHeaderField: "Accept-Ranges") else {
            logger.error("Server does not specify \"Accept-Ranges\"")
            return false
        }

        // Typically, if a server doesn't support ranges, it omits Accept-Ranges, but sometimes sets to "none"
        guard acceptRanges == "bytes" else {
            logger.error("Server specified \"Accept-Ranges\"=\(acceptRanges) when \"bytes\" was expected")
            return false
        }
        logger.info("Server specified \"Accept-Ranges\"=\(acceptRanges)")

        // Also read the content length for debugging purposes
        if let contentLength = response.value(forHTTPHeaderField: "Content-Length") {
            logger.debug("Server specified \"Content-Length\"=\(contentLength)")
        }

        return true
    }

    
    private static func getContentRangeComponents(from contentRangeString: String) -> ContentRangeComponents? {
        let startRef = Reference(Substring.self)
        let endRef = Reference(Substring.self)
        let totalRef = Reference(Substring.self)
        let contentRangePattern = Regex {
            Anchor.startOfLine
            "bytes "
            Capture(as: startRef) { OneOrMore(.digit) }
            "-"
            Capture(as: endRef) { OneOrMore(.digit) }
            "/"
            Capture(as: totalRef) { OneOrMore(.digit) }
            Anchor.endOfLine
        }

        guard let match = contentRangeString.firstMatch(of: contentRangePattern) else {
            logger.error("Failed to match Content-Range pattern in \(contentRangeString)")
            return nil
        }

        let start = String(match[startRef])
        let end = String(match[endRef])
        let total = String(match[totalRef])
        logger.info("Matched start: \(start), end: \(end), total: \(total) in Content-Range string: \(contentRangeString)")

        guard let startValue = UInt64(start), let endValue = UInt64(end), let totalValue = UInt64(total) else {
            logger.error("Failed to convert Content-Range string components to UInt64")
            return nil
        }
        return ContentRangeComponents(start: startValue, end: endValue, total: totalValue)
    }

    private static func downloadRange(
        at url: URL,
        range: ClosedRange<UInt64>,
        attempts maxAttempts: Int = 1,
        backoff: BackOff = .linear(.seconds(10), offset: .seconds(5)),
        background: Bool? = nil,
    ) async throws -> RangeResult {
        var request = URLRequest(url: url)
        // disable automatic urlsession 'Accept-Encoding: gzip'
        request.addValue("identity", forHTTPHeaderField: "Accept-Encoding")

        // add range header for current range to request
        let rangeHeaderValue = "bytes=\(range.lowerBound)-\(range.upperBound)"
        request.setValue(rangeHeaderValue, forHTTPHeaderField: "Range")

        if background == true {
            logger.info("Using background network service type to fetch range: (\(range.lowerBound)-\(range.upperBound))")
            request.networkServiceType = .background
        }

        let expectedChunkSize = UInt64(range.count)
        // Perform data chunk fetch in retry loop using maxAttempts and NarrativeAuth (because this is likely an auth CDN download)
        // Specify expected content length for chunk so perform can retry if incomplete data received
        var data: Data?
        var response: HTTPURLResponse
        do {
            (data, response) = try await perform(request: request, attempts: maxAttempts, timeout: nil, syncTime: false, useNarrativeAuth: true, expectedContentLength: expectedChunkSize)
        } catch let error as Network.Error {
            switch error {
            // If perform threw due to a 416, a range was requested beyond the file size
            case .requestedRangeNotSatisfiable(let code):
                logger.log("Recieved \(code) requested range not satisfiable for range (\(range.lowerBound)-\(range.upperBound))")
                // Pass this along so we stop making further requests
                response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
            default:
                throw error
            }
        }
        return RangeResult(data: data, response: response, offset: range.lowerBound)
    }

    static func downloadRanges(
        at url: URL,
        to destinationPath: FilePath,
        attempts: Int = 1,
        backoff: BackOff = .linear(.seconds(10), offset: .seconds(5)),
        background: Bool? = nil,
        maxActiveTasks: Int,
        chunkSize: UInt64
    ) async throws {
        // Create file where data chunks will be written to ahead of time
        var fd: FileDescriptor
        do {
            fd = try FileDescriptor.open(
                destinationPath, .writeOnly,
                options: [.create, .truncate],
                permissions: .fileDefault)
        } catch {
            throw Network.Error.fileCreationFailed(error)
        }
        defer {
            do {
                try fd.close()
            } catch {
                logger.error("Failed to close file descriptor for writing to \(destinationPath): \(error)")
            }
        }

        // Init range tracker actor for determining offset of next chunk to download
        let rangeTracker = RangeTracker(chunkSize: chunkSize)

        // Sync with timed once before making all range requests (we won't sync again for each range)
        if !Time.isSynchronized {
            logger.warning("Time is not synced before making network request, continuing")
        }

        logger.log("Downloading ranges from [\(url)] to [\(destinationPath)] using max of \(maxActiveTasks) active tasks...")
        let _ = try await withThrowingTaskGroup { group in
            // Create up to kMaxActiveTasks to fetch chunks
            for _ in 0..<maxActiveTasks {
                // Seed maxActiveTasks with potential ranges to fetch. Since nextRange is oblivious to content length,
                // any extra tasks will immediately be served a 416 and no data
                let range = await rangeTracker.nextRange()
                group.addTask {
                    logger.info("Adding task to fetch range: (\(range.lowerBound)-\(range.upperBound))")
                    return try await downloadRange(at: url, range: range, attempts: attempts, backoff: backoff, background: background)
                }
            }
            for try await result in group {
                // Verify we actually got data and not nil with 416 before writing to disk
                // TODO: Note 206 check is redundant since we check this in perform() - can maybe remove?
                if (result.data != nil) && (result.response.statusCode == 206) {
                    logger.info("Received \(result.response.statusCode) status code for \(result.data!.count) byte chunk, writing to disk at offset \(result.offset)")
                    try writeChunk(to: fd, data: result.data!, at: Int64(result.offset))
                }

                // If a 416 was returned, do NOT request another range
                if result.response.statusCode != 416 {
                    let range = await rangeTracker.nextRange()
                    group.addTask {
                        logger.info("Adding task to fetch range: (\(range.lowerBound)-\(range.upperBound))")
                        return try await downloadRange(at: url, range: range, attempts: attempts, backoff: backoff, background: background)
                    }
                } else {
                    logger.log("Received 416 status code, no more data to fetch!")
                }
            }
        }
    }

    static func download(
        from url: URL,
        to path: FilePath,
        attempts maxAttempts: Int = 1,
        backoff: BackOff = .linear(.seconds(10), offset: .seconds(5)),
        background: Bool = false
    ) async throws {
        if !Time.isSynchronized {
            logger.warning("Time is not synced before making network request, continuing")
        }

        logger.log("Downloading from \(url) to \(path)")

        var request = URLRequest(url: url)
        // disable automatic urlsession 'Accept-Encoding: gzip'
        request.addValue("identity", forHTTPHeaderField: "Accept-Encoding")

        if background == true {
            logger.info("Using background network service type to download \(url)")
            request.networkServiceType = .background
        }

        // Init delegate with Narrative credential in case this is a authenticated CDN download and no timeout
        let credential = narrativeCredential
        let delegate = DataDelegate(timeout: nil, cred: credential)

        try await retry(count: maxAttempts, backoff: backoff) { attempt in
            let fileURL: URL
            let response: URLResponse

            do {
                (fileURL, response) = try await urlSession.download(for: request, delegate: delegate)
            } catch {
                throw Network.Error.connectionError(error)
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw Network.Error.noResponse
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw Network.Error.badResponse(httpResponse.statusCode)
            }

            guard let source = FilePath(fileURL) else {
                throw Network.Error.noData
            }

            defer {
                do {
                    try source.remove()
                } catch {
                    logger.error("Failed to remove temp file \(path)")
                }
            }

            do {
                try source.copy(to: path)
            } catch {
                throw Network.Error.dataTransformFailed(.error(error))
            }

        } shouldRetry: { error in
            logger.error("Download attempt \(url) failed: \(error.localizedDescription)")
            guard let error = error as? Network.Error else {
                return false
            }
            return error.shouldRetry
        }
    }

    static func downloadItem(
        at url: URL,
        to destinationDirectory: FilePath? = nil,
        attempts: Int = 3,
        backoff: BackOff = .linear(.seconds(10), offset: .seconds(5)),
        background: Bool = false,
        maxActiveTasks: Int? = nil,
        chunkSize: UInt64? = nil
    ) async -> FilePath? {
        guard let destinationDirectory = destinationDirectory ?? FilePath.createTemporaryDirectory() else {
            return nil
        }
        
        let name = if url.lastPathComponent.isEmpty || url.lastPathComponent == "/" {
            url.host() ?? "download"
        } else {
            url.lastPathComponent
        }
        
        let destinationPath = destinationDirectory.appending(name)

        if let localFilePath = FilePath(url) {
            do {
                try localFilePath.copy(to: destinationPath)
            } catch {
                logger.error("Failed to copy contents from \(localFilePath) to \(destinationPath): \(error.localizedDescription)")
                return nil
            }
        } else {
            do {
                // Determine if range requests are possible. If not, just download to disk using one request to avoid buffering large file into memory in downloadRanges. If supported, go for it!
                if await canDoRangeRequests(for: url, chunkSize: chunkSize) {
                    logger.log("Range requests supported for \(url). Will download using range requests...")
                    try await downloadRanges(at: url, to: destinationPath, attempts: attempts, backoff: backoff, maxActiveTasks: maxActiveTasks ?? kMaxActiveTasks, chunkSize: chunkSize ?? kCDNChunkSize)
                } else {
                    logger.log("Range requests unsupported for \(url). Will download full file using one request...")
                    try await download(from: url, to: destinationPath, attempts: attempts, backoff: backoff, background: background)
                }
            } catch {
                logger.error("Download failed: \(error.localizedDescription)")
                return nil
            }
        }
        logger.log( "Successfully downloaded \(url) to \(destinationPath)")
        return destinationPath
    }

    /// Performs the `request` and asynchronously returns the response.
    ///
    /// - parameter request: The url request to perform.
    /// - parameter attempts: The maximum number of retries to attempt
    /// - parameter timeout: Maximum time allowed for a single attempt
    /// - parameter backoff: The backoff strategy to use when retrying
    /// - parameter syncTime: Whether we should attempt to sync with timed
    /// - parameter useNarrativeAuth: Whether we should use Narrative mtls in response to authentication challenges
    /// - parameter expectedContentLength:The expected content length of data, used by range requests
    ///
    /// - Returns: The contents of the URL specified by the request as a `Data` instance
    private static func perform(
        request: URLRequest,
        attempts maxAttempts: Int = 3,
        timeout: Duration? = .seconds(10),
        backoff: BackOff = .linear(.seconds(10), offset: .seconds(5)),
        syncTime: Bool = true,
        useNarrativeAuth: Bool = false,
        expectedContentLength: UInt64? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        // We don't want to sync with timed if this is a range request!
        if syncTime && !Time.isSynchronized {
            logger.warning("Time is not synced before making network request, continuing")
        }
        let id = UUID()
        logger.log("Performing HTTP request \(id) \(request.logDescription)")
       
        var credential: URLCredential?
        // Don't bother attempting to fetch Narrative cert from keychain if this is just a GET, POST, etc
        if useNarrativeAuth {
            credential = narrativeCredential
        }
        let sessionDelegate = DataDelegate(timeout: timeout, cred: credential)
        return try await retry(count: maxAttempts, backoff: backoff) { attempt in
            let data: Data
            let response: URLResponse

            do {
                (data, response) = try await urlSession.data(for: request, delegate: sessionDelegate)
            } catch {
                throw Network.Error.connectionError(error)
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw Network.Error.noResponse
            }

            // Servers that support ranges will typically send a 416 when you request a range starting beyond the file size
            // Throw a specific error indicating this for callers doing range request downloads
            guard httpResponse.statusCode != 416 else {
                throw Network.Error.requestedRangeNotSatisfiable(httpResponse.statusCode)
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw Network.Error.badResponse(httpResponse.statusCode)
            }

            // If this is a range request with expected content length, need to do some special error handling
            if let expectedContentLength {
                // Range requests should receive a 206 from server if supported. 200 is unacceptable.
                // Note, as long as the range started within the file size, we expect a 206
                guard httpResponse.statusCode == 206 else {
                    throw Network.Error.badResponse(httpResponse.statusCode)
                }

                var actualExpected = expectedContentLength
                // Extract the value of "Content-Range" header with form "bytes <start byte>-<end byte>/<total bytes>"
                guard let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range") else {
                    throw Network.Error.noData
                }
                // Extract the start, end, and total bytes from Content-Range
                guard let components = getContentRangeComponents(from: contentRange) else {
                    throw Network.Error.dataTransformFailed(.incomplete("\"Content-Range\" header value not in expected form"))
                }
                // If this is the last chunk and total bytes are not a perfect multiple of expected, adjust the expected size
                if (components.end == components.total - 1) && (components.total % expectedContentLength != 0) {
                    actualExpected = components.total % expectedContentLength
                }
                // If we received incomplete data for this range, we should retry
                guard actualExpected == UInt64(data.count) else {
                    throw Network.Error.incomplete
                }
            }

            return (data, httpResponse)

        } shouldRetry: { error in
            logger.error("Request (\(id)) attempt failed: \(error.localizedDescription)")
            guard let error = error as? Network.Error else {
                return false
            }
            return error.shouldRetry
        }
    }

    /// Encodes the request as JSON and uploads it to the URL via the HTTP POST method.
    static func post<Request: Encodable>(
        _ request: Request,
        to url: URL,
        attempts: Int = 3,
        timeout: Duration = .seconds(10),
        backoff: BackOff = .linear(.seconds(10), offset: .seconds(5))
    ) async throws -> Data {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpBody = try JSONEncoder().encode(request)
        urlRequest.httpMethod = "POST"
        let (data, _) = try await perform(request: urlRequest, attempts: attempts, timeout: timeout, backoff: backoff)
        return data
    }

    /// Fetches the content of the URL via a HTTP GET request.
    static func get(
        from url: URL,
        additionalHTTPHeaders: [String: String] = [:],
        attempts: Int = 3,
        timeout: Duration = .seconds(10),
        backoff: BackOff = .linear(.seconds(10), offset: .seconds(5)),
        useNarrativeAuth: Bool = false
    ) async throws -> Data {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.addHeaders(additionalHTTPHeaders: additionalHTTPHeaders)
        let (data, _) = try await perform(request: urlRequest, attempts: attempts, timeout: timeout, backoff: backoff, useNarrativeAuth: useNarrativeAuth)
        return data
    }
    
    /// Performs a HTTP PUT request to the given URL.
    static func put(
        to url: URL,
        additionalHTTPHeaders: [String: String] = [:],
        attempts: Int = 3,
        timeout: Duration = .seconds(10),
        backoff: BackOff = .linear(.seconds(10), offset: .seconds(5))
    ) async throws -> Data {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "PUT"
        urlRequest.addHeaders(additionalHTTPHeaders: additionalHTTPHeaders)
        let (data, _) = try await perform(request: urlRequest, attempts: attempts, timeout: timeout)
        return data
    }
    
    /// Performs a HTTP HEAD request to the given URL
    static func head(
        from url: URL,
        additionalHTTPHeaders: [String: String] = [:],
        attempts: Int = 3,
        timeout: Duration = .seconds(10),
        backoff: BackOff = .linear(.seconds(10), offset: .seconds(5))
    ) async throws -> HTTPURLResponse {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "HEAD"
        urlRequest.addHeaders(additionalHTTPHeaders: additionalHTTPHeaders)
        let (_, response) = try await perform(request: urlRequest, attempts: attempts, timeout: timeout, useNarrativeAuth: true)
        return response
    }

    // Helper for getting Mellanox interface bsd name on J236
    private static func getUplinkInterfaceName() throws -> String {
        try retry(count: 5, delay: .seconds(5), backoff: .seconds(10)) { attempt in
            let domain = CFPreferences.Domain(
                applicationId: kUplinkInterfaceAppID as CFString,
                userName: kCFPreferencesAnyUser,
                hostName: kCFPreferencesCurrentHost)
            
            guard let bsdName = CFPreferences.getValue(for: kUplinkInterfaceKey, in: domain) else {
                logger.debug("Reattempting CFPref read of \(kUplinkInterfaceKey)...")
                throw UplinkInterfaceError("Failed to read \(kUplinkInterfaceKey) value")
            }
            
            return bsdName as! String
        }
    }
    
    static func unsetUplinkBandwidthLimit() -> Bool {
        guard setUplinkBandwidthLimit(bandwidthLimit: 0) else {
            logger.error("Failed to reset uplink interface bandwidth")
            return false
        }
        return true
    }

    // Configure the bandwidth limit on the Mellanox interface
    static func setUplinkBandwidthLimit(bandwidthLimit: UInt64) -> Bool {
        var bsdName: String
        do {
            try bsdName = getUplinkInterfaceName()
        } catch {
            logger.error("Failed to get uplink interface bsd name: \(error)")
            return false
        }
        logger.info("Configuring bandwidth limit for interface \(bsdName)...")
        
        // Attempt to open socket, retrying if we fail due to interrupt
        var sock:Int32
        let sockStatus = valueOrErrno(retryOnInterrupt: true) {
            socket(AF_INET, SOCK_DGRAM, 0)
        }
        switch sockStatus {
        case .success(let sockVal):
            sock = sockVal
            logger.info("Opened socket: \(sock)")
            break
        case .failure(let errnoValue):
            logger.error("Failed to open socket: \(errnoValue)")
            return false
        }
        defer {
            close(sock)
        }
        
        var iflpr = if_linkparamsreq()
        let len = withUnsafeMutablePointer(to: &iflpr.iflpr_name) { dest in
            strlcpy(dest, bsdName, Int(IFNAMSIZ))
        }
        guard len < IFNAMSIZ else {
            logger.error("Interface name '\(bsdName)' is too long for system buffer")
            return false
        }
        
        var status = ioctl(sock, kSIOCGIFLINKPARAMS, &iflpr)
        guard status == 0 else {
            logger.error("Failed to get link params for interface \(bsdName): \(Errno.current)")
            return false
        }
        logger.debug("Current bandwidth limit: \(iflpr.iflpr_input_netem.ifnetem_bandwidth_bps)")
        logger.debug("Current packet scheduler model: \(iflpr.iflpr_input_netem.ifnetem_model.rawValue)")
        
        // If we are unsetting the bandwidth limit, zero out the input netem params
        if bandwidthLimit == 0 {
            iflpr.iflpr_input_netem = if_netem_params()
        } else {
            iflpr.iflpr_input_netem.ifnetem_model = IF_NETEM_MODEL_NLC
            iflpr.iflpr_input_netem.ifnetem_bandwidth_bps = bandwidthLimit
        }
        
        status = ioctl(sock, kSIOCSIFLINKPARAMS, &iflpr)
        guard status == 0 else {
            logger.error("Failed to set link params for interface \(bsdName): \(Errno.current)")
            return false
        }
        return true
    }

    /// Writes the uplink MTU preference for `mantaremoteagentd`.
    static func setUplinkMTU(_ mtu: Int) -> Int? {

        let domain = CFPreferences.Domain(
            applicationId: kMantaRemoteAgentdBundleId as CFString,
            userName: kCFPreferencesAnyUser,
            hostName: kCFPreferencesAnyHost
        )

        do {
            try CFPreferences.setVerified(
                value: mtu as CFNumber,
                for: kUplinkMTUHintKey,
                in: domain
            )
        } catch {
            Self.logger.error("Failed to set the uplink MTU: \(error, privacy: .public)")
            return nil
        }

        return mtu
    }
}

extension Network {
    struct UplinkInterfaceError: Swift.Error, CustomStringConvertible {
        var description: String

        init(_ description: String) {
            self.description = description
        }
    }
}

extension Network {
    internal struct RangeResult {
        let data: Data?
        let response: HTTPURLResponse
        let offset: UInt64
        
    }
}

extension Network {
    internal struct ContentRangeComponents {
        let start: UInt64
        let end: UInt64
        let total: UInt64
    }
}

extension Network {
    internal enum DataTransformError {
        case error(Swift.Error)
        case incomplete(String)
    }
}

extension Network {
    internal enum Error: Swift.Error {
        case incomplete
        case connectionError(Swift.Error)
        case noResponse
        case badResponse(Int)
        case noData
        case dataTransformFailed(DataTransformError)
        case fileCreationFailed(Swift.Error)
        case requestedRangeNotSatisfiable(Int)
    }
}

extension Network.Error: LocalizedError {
    internal var errorDescription: String? {
        switch self {
        case .incomplete:
            return "Failed to complete network request"
        case let .connectionError(error):
            return "Connection failed: \(error.localizedDescription)"
        case .noResponse:
            return "Received no response from server"
        case let .badResponse(code):
            return "Received bad response \(code) from server"
        case .noData:
            return "Received no data from server"
        case let .dataTransformFailed(dataTransformError):
            switch dataTransformError {
            case .error(let error):
                return "Failed to handle received data: \(error.localizedDescription)"
            case .incomplete(let description):
                return "Failed to handle received data: \(description)"
            }
        case let .fileCreationFailed(error):
            return "Failed to create file for downloading data: \(error.localizedDescription)"
        case let .requestedRangeNotSatisfiable(code):
            return "Received \(code) requested range is not satisfiable from server"
        }
    }
}

extension Network.Error {
    internal static let retryHTTPCodes = [
        429, // Too Many Requests
        500, // Internal Server Error
        502, // Bad Gateway
        503, // Service Unavailable
        504, // Gateway Timeout
        509, // Bandwidth Limit Exceeded
    ]

    internal var shouldRetry: Bool {
        switch self {
        case .incomplete, .connectionError, .noResponse, .noData:
            return true
        case .badResponse(let code):
            return Self.retryHTTPCodes.contains(code)
        default:
            return false
        }
    }
}

extension URLRequest {
    mutating func addHeaders(additionalHTTPHeaders: [String: String]) {
        for (key, value) in additionalHTTPHeaders {
            self.addValue(value, forHTTPHeaderField: key)
        }
    }
}
