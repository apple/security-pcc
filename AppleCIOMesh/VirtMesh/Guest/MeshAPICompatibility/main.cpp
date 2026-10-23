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
//  main.cpp
//  MeshAPICompatibility
//
//  Created by Zixuan Wang on 1/23/25.
//

#include <os/log.h>
#include <utility>

/* CIOMesh APIs */
#include "Kext/AppleCIOMeshConfigUserClientInterface.h"
#include "Kext/AppleCIOMeshUserClientInterface.h"

/* Undef a few macros to prevent compilation conflicts */
#undef kMaxMessageCount
#undef kMaxConnectedNodeCount
#undef kMaxACIOCount
#undef kNonDCHardwarePlatform
#undef kMaxHostnameLength
#undef kMaxPeerCount

/* VirtMesh APIs */
#include "VirtMesh/Guest/AppleVirtMesh/Interfaces.h"

namespace Bare
{
namespace Main   = AppleCIOMeshUserClientInterface;
namespace Config = AppleCIOMeshConfigUserClientInterface;
}; // namespace Bare

namespace Virt
{
namespace Main   = VirtMesh::Guest::Mesh::MainClient;
namespace Config = VirtMesh::Guest::Mesh::ConfigClient;
}; // namespace Virt

#define check(lhs, rhs)                \
	do {                               \
		static_assert((lhs) == (rhs)); \
	} while (0)

#define check_enum(ns, virt_enum, bare_enum)                                                     \
	do {                                                                                         \
		check(std::to_underlying(Virt::ns::virt_enum), std::to_underlying(Bare::ns::bare_enum)); \
	} while (0)

#define check_size(ns, virt_struct, bare_struct)                             \
	do {                                                                     \
		check(sizeof(Virt::ns::virt_struct), sizeof(Bare::ns::bare_struct)); \
	} while (0)

#define check_value(ns, virt_value, bare_value)            \
	do {                                                   \
		check(Virt::ns::virt_value, Bare::ns::bare_value); \
	} while (0)

#define check_const(ns, virt_const, bare_const)  \
	do {                                         \
		check_size(ns, virt_const, bare_const);  \
		check_value(ns, virt_const, bare_const); \
	} while (0)

int
main()
{
	/* Main APIs */
	check_enum(Main, Methods::NotificationRegister, Method::NotificationRegister);
	check_enum(Main, Methods::NotificationUnregister, Method::NotificationUnregister);
	check_enum(Main, Methods::AllocateSharedMemory, Method::AllocateSharedMemory);
	check_enum(Main, Methods::DeallocateSharedMemory, Method::DeallocateSharedMemory);
	check_enum(Main, Methods::AssignSharedMemoryChunk, Method::AssignSharedMemoryChunk);
	check_enum(Main, Methods::PrintBufferState, Method::PrintBufferState);
	check_enum(Main, Methods::SetupForwardChainBuffers, Method::SetupForwardChainBuffers);
	check_enum(Main, Methods::SetMaxWaitTime, Method::SetMaxWaitTime);
	check_enum(Main, Methods::SetMaxWaitPerNodeBatch, Method::SetMaxWaitPerNodeBatch);
	check_enum(Main, Methods::SynchronizeGeneration, Method::SynchronizeGeneration);
	check_enum(Main, Methods::OverrideRuntimePrepare, Method::OverrideRuntimePrepare);
	check_enum(Main, Methods::TotalMethods, Method::NumMethods);

	check_enum(Main, Traps::WaitSharedMemoryChunk, Trap::WaitSharedMemoryChunk);
	check_enum(Main, Traps::SendAssignedData, Trap::SendAssignedData);
	check_enum(Main, Traps::PrepareChunk, Trap::PrepareChunk);
	check_enum(Main, Traps::PrepareAllChunks, Trap::PrepareAllChunks);
	check_enum(Main, Traps::SendAndPrepareChunk, Trap::SendAndPrepareChunk);
	check_enum(Main, Traps::SendAllAssignedChunks, Trap::SendAllAssignedChunks);
	check_enum(Main, Traps::ReceiveAll, Trap::ReceiveAll);
	check_enum(Main, Traps::ReceiveNext, Trap::ReceiveNext);
	check_enum(Main, Traps::ReceiveBatch, Trap::ReceiveBatch);
	check_enum(Main, Traps::ReceiveBatchForNode, Trap::ReceiveBatchForNode);
	check_enum(Main, Traps::InterruptWaitingThreads, Trap::InterruptWaitingThreads);
	check_enum(Main, Traps::ClearInterruptState, Trap::ClearInterruptState);
	check_enum(Main, Traps::InterruptReceiveBatch, Trap::InterruptReceiveBatch);
	check_enum(Main, Traps::StartForwardChain, Trap::StartForwardChain);
	check_enum(Main, Traps::StopForwardChain, Trap::StopForwardChain);
	check_enum(Main, Traps::TotalTraps, Trap::NumTraps);

	check_size(Main, SharedMemoryConfig, SharedMemory);
	check(Virt::Main::kMaxBufferChunkSize, kMaxChunkSize);

	/* Config APIs */
	check_enum(Config, Methods::NotificationRegister, Method::NotificationRegister);
	check_enum(Config, Methods::NotificationUnregister, Method::NotificationUnregister);
	check_enum(Config, Methods::GetHardwareState, Method::GetHardwareState);
	check_enum(Config, Methods::SetExtendedNodeId, Method::SetExtendedNodeId);
	check_enum(Config, Methods::GetExtendedNodeId, Method::GetExtendedNodeId);
	check_enum(Config, Methods::GetLocalNodeId, Method::GetLocalNodeId);
	check_enum(Config, Methods::SetChassisId, Method::SetChassisId);
	check_enum(Config, Methods::AddPeerHostname, Method::AddPeerHostname);
	check_enum(Config, Methods::GetPeerHostnames, Method::GetPeerHostnames);
	check_enum(Config, Methods::Activate, Method::Activate);
	check_enum(Config, Methods::Deactivate, Method::Deactivate);
	check_enum(Config, Methods::Lock, Method::Lock);
	check_enum(Config, Methods::DisconnectCIOChannel, Method::DisconnectCIOChannel);
	check_enum(Config, Methods::EstablishTxConnection, Method::EstablishTxConnection);
	check_enum(Config, Methods::GetConnectedNodes, Method::GetConnectedNodes);
	check_enum(Config, Methods::SendControlMessage, Method::SendControlMessage);
	check_enum(Config, Methods::IsLocked, Method::IsLocked);
	check_enum(Config, Methods::GetCIOConnectionState, Method::GetCIOConnectionState);
	check_enum(Config, Methods::SetCryptoKey, Method::SetCryptoKey);
	check_enum(Config, Methods::GetCryptoKey, Method::GetCryptoKey);
	check_enum(Config, Methods::GetBuffersUsedByKey, Method::GetBuffersUsedByKey);
	check_enum(Config, Methods::CanActivate, Method::canActivate);
	check_enum(Config, Methods::TotalMethods, Method::NumMethods);

	check_size(Config, HardwareState, HardwareState);
	check_size(Config, NodeId, NodeId);
	check_size(Config, ChassisId, ChassisId);
	check_size(Config, MeshChannelIdx, MeshChannelIdx);
	check_size(Config, MeshMessage, MeshMessage);
	check_size(Config, NodeInfo, NodeInfo);
	check_size(Config, ConnectedNodes, ConnectedNodes);
	check_size(Config, CIOConnection, CIOConnection);
	check_size(Config, CIOConnections, CIOConnections);
	check_size(Config, MeshNodeCount, MeshNodeCount);
	// check_size(Config, AppleCIOMeshCryptoKey, AppleCIOMeshCryptoKey);
	check_enum(Config, Notification::MeshChannelChange, Notification::MeshChannelChange);
	check_enum(Config, Notification::TXNodeConnectionChange, Notification::TXNodeConnectionChange);
	check_enum(Config, Notification::RXNodeConnectionChange, Notification::RXNodeConnectionChange);
	check_size(Config, MeshChannelInfo, MeshChannelInfo);
	check_size(Config, NodeConnectionInfo, NodeConnectionInfo);
	check_size(Config, PeerNode, PeerNode);
	check_size(Config, PeerHostnames, PeerHostnames);

	os_log_info(OS_LOG_DEFAULT, "Mesh APIs are compatible");
	return 0;
}
