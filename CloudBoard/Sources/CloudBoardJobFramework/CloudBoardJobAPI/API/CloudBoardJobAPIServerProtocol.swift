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

package import CloudBoardDomain
import Foundation

package struct CloudBoardJobAPIPIRRequest: Sendable, Equatable {
    package var payload: Data
    package var purpose: String
    package var traceContext: PIRRequestTraceContext

    package init(payload: Data, purpose: String, traceContext: PIRRequestTraceContext) {
        self.payload = payload
        self.purpose = purpose
        self.traceContext = traceContext
    }
}

package struct CloudBoardJobAPIPIRResponse: Sendable, Equatable {
    package var payload: Data

    package init(payload: Data) {
        self.payload = payload
    }
}

/// CloudApp-end of the XPC protocol.
///
/// Facilitates sending the messages back to CloudBoardJobHelper.
package protocol CloudBoardJobAPIServerToClientProtocol {
    func provideResponseChunk(_ data: Data) async
    /// A serious error has occured in the cloud app - treat as a failure
    func internalError() async
    func reportRequestExecutionError(_ error: RequestExecutionError) async
    func endOfResponse() async
    func endJob() async
    func findWorker(
        query: FindWorkerQuery,
        subrequestID: UInt64?,
        cryptoMaterialHandles: [CryptoMaterialHandle]
    ) async throws
    func sendWorkerRequestMessage(workerID: UUID, _ data: Data) async
    func sendWorkerEOF(workerID: UUID, isError: Bool) async
    func finalizeRequestExecutionLog() async

    func makePrivateInformationRetrievalRequest(
        _ request: CloudBoardJobAPIPIRRequest
    ) async throws -> CloudBoardJobAPIPIRResponse
    func sendSubresponsePayload(subrequestID: UInt64, payload: Data) async
    func sendSubresponseEOF(subrequestID: UInt64, status: InternalSubresponseStatus) async
    func makeToolInvocationRequest(
        _ request: PCCToolInvocationRequest
    ) async throws -> PCCToolInvocationResponse
    func sendComponentTimeMeasurement(measurement: ComponentTimeMeasurement) async

    func sendPersistentServiceQuery(
        to identity: PersistentService.Identity,
        payload: Data,
        correlationID: PersistentService.QueryCorrelationID,
        timeout: Duration?
    ) async

    func informPersistentServiceBlocked(
        on correlationIDs: [PersistentService.QueryCorrelationID]
    ) async
}

/// CloudBoardJobHelper-end of the XPC protocol.
///
/// The two protocols are subtly different due to the defined message(and more importantly their response) types,
/// as well as semantics of asynchronous message handler ordering.
package protocol CloudBoardJobAPICloudAppResponseHandlerProtocol: Sendable {
    /// Should not be async to avoid chunk reordering
    func handleResponseChunk(_ data: Data)

    /// Tell CloudBoard that we have experienced a terminal error.
    func handleInternalError() async throws

    func handleRequestExecutionError(_ error: CloudAppToJobHelperRequestExecutionError) async throws

    /// Tell CloudBoard that we are done sending response chunks.
    func handleEndOfResponse() async throws

    /// CloudApp will attempt to wait until it has been told that the EndJob message has been handled
    func handleEndJob() async throws

    /// Handles CloudApp's request to find a worker.
    ///
    /// This _should_ ideally only return once requested worker has been found for a cleaner API, instead of
    /// a separate call to send the workerFound message.
    func handleFindWorker(_ findWorkerMessage: FindWorkerMessage) async throws

    /// Handle CloudApp request to a specific worker.
    ///
    /// CloudApp fires-and-forgets
    func handleWorkerRequestMessage(_ workerRequestMessage: WorkerRequestMessage)

    /// Tell the worker we're done
    func handleWorkerEOF(_ workerEOF: WorkerEOF)

    /// Finalize request execution log
    func handleFinaliseRequestExecutionLog()

    func handleComponentTimeMeasurement(_ measurement: ComponentTimeMeasurement)

    /// Not throwing, notifications of errors come in the response stream
    func handlePersistentServiceQuery(_ query: CloudAppToJobHelperPersistentServiceQuery)

    func handlePersistentServiceInformBlocked(
        _ message: CloudAppToJobHelperPersistentServiceInformBlocked
    ) async throws

    /// XPC connection has been disconnected. Cleanly or otherwise.
    ///
    /// No way of recovering from this.
    func disconnected(error: Error?)
}

package protocol CloudBoardJobAPIServerDelegateProtocol:
AnyObject, Sendable, CloudBoardJobAPIClientToServerProtocol {}

package protocol CloudBoardJobAPIServerProtocol: CloudBoardJobAPIServerToClientProtocol, Sendable {
    func set(delegate: CloudBoardJobAPIServerDelegateProtocol) async
    func connect() async
}
