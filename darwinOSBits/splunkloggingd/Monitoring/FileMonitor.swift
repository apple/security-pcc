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
//  FileMonitor.swift
//  splunkloggingd
//
//  Copyright © 2024 Apple, Inc.  All rights reserved.
//

import Foundation
import os

fileprivate let log = Logger(subsystem: sharedSubsystem, category: "FileMonitor")


// MARK: FileMonitorDelegate
/// A protocol that allows delegates of `FileMonitor` to respond to changes in a directory.
protocol FileMonitorDelegate: AnyObject, Sendable {
    func didObserveChange(FileMonitor: FileMonitor) async
    func didStartMonitoring(FileMonitor: FileMonitor) async
    func didStopMonitoring(FileMonitor: FileMonitor) async
}

public enum FileMonitorError: Error {
    case doesNotExist(atPath: String)
    case unableToOpenFile(atPath: String)
    case notReadable(atPath: String)
}

// MARK: FileMonitor
actor FileMonitor {
    // MARK: Properties
    /// A dispatch queue used for sending file changes in the directory.
    let queue = DispatchQueue(label: "com.apple.splunkloggingd.file-monitor")

    /// The `FileMonitor`'s delegate who is responsible for responding to `FileMonitor` updates.
    weak var delegate: FileMonitorDelegate?

    /// A file descriptor for the monitored directory.
    var fileDes: CInt = -1

    /// A dispatch source to monitor a file descriptor created from the directory.
    var fileMonitorSource: DispatchSourceFileSystemObject?
    var deleteMonitorSource: DispatchSourceFileSystemObject?
    var folderMonitorSource: DispatchSourceFileSystemObject?
    var periodicSource: DispatchSourceTimer?

    /// URL for the enclosing folder being monitored.
    let folderURL: URL
    /// URL for the property list file being monitored.
    let url: URL

    // State enumerates the possible situations we are facing to
    // monitor the config file:
    // 1. initial
    //      - we just started up
    // 2. monitorFile
    //      - happy path
    //      - the file exists and we monitor for any changes
    // 3. monitorEnclosingFolder
    //      - the file doesn't exist or it was removed
    //      - watch the folder for any changes
    // 4. periodicallyCheckForEnclosingFolder
    //      - the enclosing folder doesn't exist, so periodically
    //        check for it
    enum State {
        case initial
        case monitorFile
        case monitorEnclosingFolder
        case periodicallyCheckForEnclosingFolder
    }
    var state: State = .initial

    // MARK: Initializers
    init(url: URL, delegate: FileMonitorDelegate? = nil) {
        self.url = url
        self.delegate = delegate
        self.folderURL = URL(fileURLWithPath: ".", relativeTo: url)
    }

    func setDelegate(_ newDelegate: FileMonitorDelegate) async {
        self.delegate = newDelegate
    }

    func getState() async -> State {
        return self.state
    }

    // MARK: Monitoring
    private func handleInitialState() {
        log.info("state = .initial \(self.url.absoluteString, privacy: .public)")
        fileDes = open((self.url as NSURL).fileSystemRepresentation, O_EVTONLY)
        if fileDes >= 0 {
            state = .monitorFile
            Task { await delegate?.didStartMonitoring(FileMonitor: self) }
            return self.startMonitoring()
        }
        fileDes = open((self.folderURL as NSURL).fileSystemRepresentation, O_EVTONLY)
        if fileDes >= 0 {
            state = .monitorEnclosingFolder
            return self.startMonitoring()
        }
        state = .periodicallyCheckForEnclosingFolder
        return self.startMonitoring()
    }

    private func handleMonitorFileState() {
        log.info("state = .monitorFile \(self.url.absoluteString, privacy: .public)")
        fileMonitorSource = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDes,
                                                                      eventMask: [.attrib, .extend, .write],
                                                                      queue: queue)
        deleteMonitorSource = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDes,
                                                                        eventMask: .delete,
                                                                        queue: queue)
       fileMonitorSource?.setEventHandler {
            // Call out to the `FileMonitorDelegate` so that it can react appropriately to the change.
            log.info("didObserveChange in File")
           Task { await self.delegate?.didObserveChange(FileMonitor: self) }
        }

        deleteMonitorSource?.setEventHandler {
            log.info("monitored file was deleted")
            self.fileMonitorSource?.cancel()
            self.fileDes = -1
            self.state = .monitorEnclosingFolder
            self.deleteMonitorSource = nil
            return self.startMonitoring()
        }

        fileMonitorSource?.resume()
        deleteMonitorSource?.resume()
    }

    private func handleMonitorEnclosingFolderState() {
        if fileDes >= 0 {
            close(fileDes)
        }
        self.fileMonitorSource = nil
        fileDes = open((folderURL as NSURL).fileSystemRepresentation, O_EVTONLY)
        log.info("state = .monitorEnclosingFolder \(self.folderURL.absoluteString, privacy: .public) = \(self.fileDes, privacy: .public)")
        guard fileDes >= 0 else {
            state = .periodicallyCheckForEnclosingFolder
            return self.startMonitoring()
        }
        folderMonitorSource = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDes,
                                                                        eventMask: [.extend, .write, .attrib, .link],
                                                                        queue: queue)
        deleteMonitorSource = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDes,
                                                                        eventMask: .delete,
                                                                        queue: queue)
        folderMonitorSource?.setEventHandler {
            log.info("didObserveChange in enclosing Folder")
            let fd = open((self.url as NSURL).fileSystemRepresentation, O_EVTONLY)
            if fd >= 0 {
                close(self.fileDes)
                self.fileDes = fd
                self.state = .monitorFile
                self.folderMonitorSource = nil

                // Creating the file is a change in the file
                log.info("didObserveChange in File")
                Task { await self.delegate?.didObserveChange(FileMonitor: self) }
                return self.startMonitoring()
            }
        }

        deleteMonitorSource?.setEventHandler {
            log.info("monitored folder was deleted")
            self.folderMonitorSource?.cancel()
            close(self.fileDes)
            self.fileDes = -1
            self.state = .periodicallyCheckForEnclosingFolder
            self.deleteMonitorSource = nil
            return self.startMonitoring()
        }
        folderMonitorSource?.resume()
        deleteMonitorSource?.resume()
    }

    private func handlePeriodicallyCheckForEnclosingFolderState() {
        log.info("state = .periodicallyCheckForEnclosingFolder \(self.folderURL.absoluteString, privacy: .public)")
        periodicSource = DispatchSource.makeTimerSource(queue: self.queue)
        periodicSource?.schedule(deadline: .now() + 5.0, repeating: 5.0)
        periodicSource?.setEventHandler {
            self.fileDes = open((self.folderURL as NSURL).fileSystemRepresentation, O_EVTONLY)
            guard self.fileDes >= 0 else { return }
            self.periodicSource?.cancel()
            self.periodicSource = nil
            self.state = .monitorEnclosingFolder
            return self.startMonitoring()
        }
        periodicSource?.activate()
    }

    func startMonitoring() {
        switch state {
        case .initial:
            return self.handleInitialState()

        case .monitorFile:
            return self.handleMonitorFileState()

        case .monitorEnclosingFolder:
            return self.handleMonitorEnclosingFolderState()

        case .periodicallyCheckForEnclosingFolder:
            return self.handlePeriodicallyCheckForEnclosingFolderState()
        }
    }

    func stopMonitoring() {
        // Stop listening for changes to the directory, if the source has
        // already been created.
        fileMonitorSource?.cancel()
        deleteMonitorSource?.cancel()
        folderMonitorSource?.cancel()
        // Notify the delegate that we stopped monitoring
        log.info("Stopped Monitoring file: \(self.url, privacy: .public)")
        Task { await delegate?.didStopMonitoring(FileMonitor: self) }
    }
}
