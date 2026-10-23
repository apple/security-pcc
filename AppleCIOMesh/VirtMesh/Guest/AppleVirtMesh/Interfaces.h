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
//  Interfaces.h
//  AppleVirtMesh
//
//  Created by Zixuan Wang on 11/19/24.
//

#pragma once

#include "VirtMesh/Guest/AppleVirtMesh/Config.h"
#include <stdint.h>

#ifdef KERNEL
#include <IOKit/IOLib.h>
#include <IOKit/IOTypes.h>
#else
#include <IOKit/IOKitLib.h>
using mach_vm_address_t = uint64_t;
#endif

namespace VirtMesh::Guest::Mesh
{

enum class MeshClientType : uint32_t {
	MainClient   = 0,
	ConfigClient = 1,
};

static constexpr uint32_t kMaxVRENodes = 2;

static constexpr uint32_t kMaxMeshLinkCount = 8;
static constexpr uint32_t kNumDataPaths     = 2;

static constexpr uint32_t kMaxMeshLinksPerChannel = 2;
static constexpr uint32_t kMaxMeshChannelCount    = kMaxMeshLinkCount / kMaxMeshLinksPerChannel;

static constexpr uint32_t kMaxMessageCount = 128;

static constexpr uint32_t kVREMeshLinksPerChannel = 1;
static constexpr uint32_t kVREMeshChannelCount    = 1;
static constexpr uint32_t kVREMeshLinkCount       = 1;

/**
 * @brief Config client interfaces
 *
 * @ref AppleCIOMesh/Kext/AppleCIOMeshConfigUserClientInterface.h
 */
namespace ConfigClient
{
enum Methods : uint32_t {
	NotificationRegister = 0,
	NotificationUnregister,
	GetHardwareState,
	SetExtendedNodeId,
	GetExtendedNodeId,
	GetLocalNodeId,
	SetChassisId,
	AddPeerHostname,
	GetPeerHostnames,
	Activate,
	Deactivate,
	Lock,
	DisconnectCIOChannel,
	EstablishTxConnection,
	GetConnectedNodes,
	SendControlMessage,
	IsLocked,
	GetCIOConnectionState,
	SetCryptoKey,
	GetCryptoKey,
	GetBuffersUsedByKey,
	CanActivate,
	SetEnsembleSize,
	GetEnsembleSize,
	TotalMethods
};

struct HardwareState {
	uint32_t meshLinksPerChannel;
	uint32_t meshChannelCount;
	uint32_t maxMeshChannelCount;
	uint32_t meshLinkCount;
	uint32_t maxMeshLinkCount;
} __attribute__((packed));

typedef struct NodeId {
	uint32_t id = UINT32_MAX;
} NodeId;

static constexpr NodeId NodeIdInvalid = NodeId(UINT32_MAX);

#define kMaxChassisIdLength 32
typedef struct ChassisId {
	char id[kMaxChassisIdLength];
	ChassisId()
	{
		memset(id, 0xff, kMaxChassisIdLength);
	}
} ChassisId;

typedef uint32_t MeshChannelIdx;

static constexpr const uint32_t & kMaxMessageLength = Config::kCommandMessageDataSize;

struct MeshMessage {
	NodeId   node;
	uint32_t length;
	uint8_t  rawData[kMaxMessageLength];
} __attribute__((packed));

static constexpr uint32_t kMaxConnectedNodeCount = 8;

struct NodeInfo {
	uint8_t   rank;
	uint8_t   partitionIdx;
	int8_t    inputChannel;
	uint8_t   outputChannels[8];
	uint8_t   outputChannelCount;
	ChassisId chassisId;
} __attribute__((packed));

struct ConnectedNodes {
	struct NodeInfo nodes[kMaxConnectedNodeCount];
	uint32_t        nodeCount;
} __attribute__((packed));

static constexpr uint32_t kMaxACIOCount          = 8;
static constexpr uint32_t kNonDCHardwarePlatform = 0xDEADBEEF;

struct CIOConnection {
	bool     cableConnected;
	uint32_t expectedPeerHardwareNodeId;
	uint32_t actualPeerHardwareNodeId;
} __attribute__((packed));

struct CIOConnections {
	struct CIOConnection cio[kMaxACIOCount];
	uint32_t             cioCount;
} __attribute__((packed));

enum class CryptoFlags : uint32_t {
	CryptoAES_GCM_128,
};

struct CryptoInfo {
	void *      keyData;
	size_t      keyDataLen;
	CryptoFlags flags;

	explicit CryptoInfo(void * data, const size_t len) : keyData(data), keyDataLen(len), flags(CryptoFlags::CryptoAES_GCM_128)
	{
	}

	/* TODO: who owns the keyData? Should we free them here? CIOMesh kext does not have constructor/destructor */
} __attribute__((packed));

typedef uint32_t MeshNodeCount;
typedef uint32_t EnsembleSize;
typedef struct AppleCIOMeshCryptoKey {
	uint64_t key[4];
	AppleCIOMeshCryptoKey()
	{
		memset(key, 0xff, sizeof(key));
	}
} __attribute__((packed)) AppleCIOMeshCryptoKey;
static constexpr size_t   kUserKeySize = sizeof(AppleCIOMeshCryptoKey);

enum class Notification : uint32_t {
	MeshChannelChange,
	TXNodeConnectionChange,
	RXNodeConnectionChange,
};

struct MeshChannelInfo {
	MeshChannelIdx channelIndex;
	NodeId         node;
	ChassisId      chassis;
} __attribute__((packed));

struct NodeConnectionInfo {
	MeshChannelIdx channelIndex;
	NodeId         node;
} __attribute__((packed));

static constexpr uint32_t kMaxHostnameLength = 128;
static constexpr uint32_t kMaxPeerCount      = 3;

typedef struct PeerNode {
	NodeId nodeId;
	char   hostname[kMaxHostnameLength];
} PeerNode;

typedef struct PeerHostnames {
	uint32_t count;
	PeerNode peers[kMaxPeerCount];
} PeerHostnames;

}; // namespace ConfigClient

/**
 * @brief Main client interfaces
 *
 * @ref AppleCIOMesh/Kext/AppleCIOMeshUserClientInterface.h
 */
namespace MainClient
{
enum Methods : uint32_t {
	NotificationRegister = 0,
	NotificationUnregister,
	AllocateSharedMemory,
	DeallocateSharedMemory,
	AssignSharedMemoryChunk,
	PrintBufferState,
	SetupForwardChainBuffers,
	SetMaxWaitTime,
	SetMaxWaitPerNodeBatch,
	SynchronizeGeneration,
	OverrideRuntimePrepare,
	TotalMethods
};

enum Traps : uint32_t {
	WaitSharedMemoryChunk,
	SendAssignedData,
	PrepareChunk,
	PrepareAllChunks,
	SendAndPrepareChunk,
	SendAllAssignedChunks,
	ReceiveAll,
	ReceiveNext,
	ReceiveBatch,
	ReceiveBatchForNode,
	InterruptWaitingThreads,
	ClearInterruptState,
	InterruptReceiveBatch,
	StartForwardChain,
	StopForwardChain,
	TotalTraps
};

/**
 * @ref AppleCIOMesh/Common/Config.h
 */
const uint32_t kMaxTBTCommandCount = 8;

using BufferId       = uint64_t;
using ForwardChainId = uint8_t;

struct SharedMemoryConfig {
	BufferId          bufferId;
	mach_vm_address_t address; /* The user space buffer address */
	uint64_t          size;
	uint64_t          chunkSize;
	uint64_t          strideSkip;
	uint64_t          strideWidth;
	bool              forwardChainRequired;
	uint64_t          forwardBreakdown[kMaxTBTCommandCount + 1];
} __attribute__((packed));

struct SharedMemoryRef {
	BufferId bufferId;
	uint64_t size;
} __attribute__((packed));

enum class MeshDirection : uint8_t { In = 0x1, Out = 0x2 };

enum class Notification : uint32_t {
	IncomingData,
	SendDataComplete,
	MeshSynchronized,
};

enum class AccessMode : uint8_t {
	Notification = 0x1,
	Block        = 0x2,
};

struct AssignChunks {
	BufferId             bufferId;
	uint64_t             offset;
	uint64_t             size;
	MeshDirection        direction;
	uint64_t             meshChannelMask;
	AccessMode           accessMode;
	ConfigClient::NodeId sourceNode;
} __attribute__((packed));

struct ForwardChain {
	BufferId startBufferId;
	int64_t  startOffset;
	int64_t  endOffset;
	BufferId endBufferId;
} __attribute__((packed));

struct MaxWaitTime {
	uint64_t maxWaitTime;
} __attribute__((packed));

/* Limited by virtio queue size */
static constexpr uint64_t kMaxMessageHeaderSize = 1024;
static constexpr uint64_t kMaxSingleVirtIOTransfer =
    1 * 1024 * 1024 - kMaxMessageHeaderSize; // Keep sync with Message::kMaxPayloadSize
static constexpr uint64_t kMaxBufferChunkSize = 15 * 1024 * 1024;

static constexpr uint32_t kTagSize = 16;
struct CryptoTag {
	uint64_t value[2]; /* Match the tag size */
};

}; // namespace MainClient

}; // namespace VirtMesh::Guest::Mesh
