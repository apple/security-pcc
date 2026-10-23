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

// Copyright 2021, Apple Inc. All rights reserved.

#pragma once

#include "Common/Config.h"
#include <stdint.h>

namespace AppleCIOMeshConfigUserClientInterface
{
#define kMaxConnectedNodeCount 8
#define kMaxACIOCount 8
#define kMaxPeerCount 3
#define kMaxChassisIdLength 32
#define kMaxHostnameLength 128
#define kMaxMessageLength kCommandMessageDataSize
#define kMinTransferSize kIOThunderboltMaxFrameSize
#define kMaxMessageCount 128
#define kNonDCHardwarePlatform 0xDEADBEEF

static const char * matchingName                       = "AppleCIOMeshService";
static const uint32_t AppleCIOMeshConfigUserClientType = 1;

/// NodeId is the same as rank for distributed inference. It has no relation
/// to hardware node id.
typedef uint32_t NodeId;

/// Partition index indicates which partition this node is in.
typedef uint8_t PartitionIdx;

/// The mesh channel index when assigning inputs+output or getting channel
/// and connection change updates.
typedef uint32_t MeshChannelIdx;

/// The number of nodes in the mesh
typedef uint32_t MeshNodeCount;

typedef uint32_t EnsembleSize;

/// The chassisID of each node.
typedef struct ChassisId {
	char id[kMaxChassisIdLength];
} ChassisId;

/// The hostname and rank of a network-connected peer node.
typedef struct PeerNode {
	NodeId nodeId;
	char hostname[kMaxHostnameLength];
} PeerNode;

/// The network connected peer nodes.
typedef struct PeerHostnames {
	uint32_t count;
	PeerNode peers[kMaxPeerCount];
} PeerHostnames;

static const NodeId kUnassignedNode = 0xFFFFFFFF;

class Method
{
  public:
	enum : uint32_t {
		NotificationRegister,
		NotificationUnregister,

		// --- Configuration Methods ---
		// Gets CIO Hardware information.
		GetHardwareState,
		// Sets the current node's ID. Takes a NodeId.
		SetExtendedNodeId,
		// Gets the current node's ID
		GetExtendedNodeId,
		// Gets the current node's ID relative to its partition (0-7)
		GetLocalNodeId,
		// Set the chassis ID the node belongs to. Takes a ChassisId;
		SetChassisId,
		// Set the hostnames of the node's peers. Takes a PeerHostnames.
		AddPeerHostname,
		// Get the hostnames of the node's peers.
		GetPeerHostnames,
		// Activates all CIO interfaces. The NodeID and ChassisID must be set
		// prior to activation.
		Activate,
		// Immediately shutdown all CIO interfaces. This will kill all ongoing
		// transfers. All CIO connections and routes will need to recreated.
		// CIO will be unlocked after this.
		Deactivate,
		// Locks any further CIO connections and channels from being created.
		// This is a one-way operation. No further configuration methods will work
		// other than Deactivate.
		Lock,
		// Disconnects a CIO channel. This is a one way operation, the only way
		// to setup this channel again is deactivate and re-activate. Note, the
		// other side of the connection would also have to re-activate if they
		// disconnected the CIO Channel.
		// Takes a MeshChannelIdx.
		DisconnectCIOChannel,
		// Establish a transmit connection to a source node along a Mesh CIO
		// channel. The connection is only established when the NodeConnectionChange
		// notification comes back.
		// Takes a NodeConnectionInfo.
		EstablishTxConnection,
		// Gets a list of mesh connected nodes. Returns ::ConnectedNodes.
		GetConnectedNodes,
		// --- Message Methods ---
		// Sends a control message to the destination node through the Mesh.
		// Takes a NodeMessage.
		SendControlMessage,
		// Is the CIO Mesh config locked?  If so then mesh communication can
		// proceed.  Otherwise most functions will return an error.
		IsLocked,
		// Returns the CIO cable connectivy state. This includes if a cable
		// has been plugged in and if the peer is the expected peer. Returns
		// ::CIOConnections.
		GetCIOConnectionState,
		// Set the crypto key
		SetCryptoKey,
		// Get the crypto key
		GetCryptoKey,
		// Get the number of buffers allocated with this crypto key.
		GetBuffersUsedByKey,
		// Checks number of available XDomain link connections to see if
		// the mesh can be activated
		canActivate,
		// Sets the size of the ensemble
		SetEnsembleSize,
		// Get the size of the ensemble
		GetEnsembleSize,

		NumMethods
	};
};

enum class Notification : uint32_t {
	// A mesh channel change has occured. This notification will come with a
	// ::MeshChannelInfo and a Bool for connection status.
	MeshChannelChange,
	// A node TX connection change has occured. This notification will come with
	// ::NodeConnectionInfo, and a Bool for connection status.
	TXNodeConnectionChange,
	// A node RX connection change has occured. This notification will come with
	// ::NodeConnectionInfo, and a Bool for connection status.
	RXNodeConnectionChange,
};

/// Mesh channel information.
struct MeshChannelInfo {
	// Mesh Channel Index. This is the handle to the channel used between the
	// kext and framework.
	MeshChannelIdx channelIndex;
	// The node connected over the CIO Mesh channel.
	NodeId node;
	// The chassis the CIO mesh channel is connected to.
	ChassisId chassis;
} __attribute__((packed));

/// Node connection information.
struct NodeConnectionInfo {
	// The mesh channel the connection to the node is over.
	MeshChannelIdx channelIndex;
	// The node the connection is referring to.
	NodeId node;
} __attribute__((packed));

/// Mesh control message to/from another node.
struct MeshMessage {
	// The node the message is originating from or the node the message
	// is destined from. This will switch depending on whether this is used
	// from SendControlMessage or IncomingMessage in the shared buffer.
	NodeId node;
	// The length of the message.
	uint32_t length;
	// The raw message data.
	uint8_t rawData[kMaxMessageLength];
} __attribute__((packed));

/// CIO hardware state.
struct HardwareState {
	// Number of mesh links per channel.
	uint32_t meshLinksPerChannel;
	// Number of mesh channels connected.
	uint32_t meshChannelCount;
	// Maximum number of mesh channels supported.
	uint32_t maxMeshChannelCount;
	// Number of mesh links connected.
	uint32_t meshLinkCount;
	// Maximum number of mesh links supported.
	uint32_t maxMeshLinkCount;
} __attribute__((packed));

/// Connected node information.
struct NodeInfo {
	// Local rank of the node.
	uint8_t rank;
	// Partition the node is in.
	uint8_t partitionIdx;
	// The input channel index used by the driver for this node. -1 if this is
	// self, or the channel has not been established.
	int8_t inputChannel;
	// All the output channels the data for this rank has to go over. This
	// is used to indicate self output or forwarding if input channel is set.
	uint8_t outputChannels[8];
	// The number of channels to send data out on.
	uint8_t outputChannelCount;
	// The chassisID of this node.
	ChassisId chassisId;
} __attribute__((packed));

/// CIO Mesh connected nodes.
struct ConnectedNodes {
	struct NodeInfo nodes[kMaxConnectedNodeCount];
	// The number of nodes connected;
	uint32_t nodeCount;
} __attribute__((packed));

/// CIO connection state.
struct CIOConnection {
	// If a cable is plugged in on the CIO port.
	bool cableConected;
	// The expected peer hardware node. For NonDC hardware platforms this will
	// be kNonDCHardwarePlatform.
	uint32_t expectedPeerHardwareNodeId;
	// The actual peer hardware node. For NonDC hardware platforms this will
	// be kNonDCHardwarePlatform.
	uint32_t actualPeerHardwareNodeId;
} __attribute__((packed));

/// CIO Mesh connections.
struct CIOConnections {
	// CIO Connection information for each ACIO.
	struct CIOConnection cio[kMaxACIOCount];
	// Number of acios on the platform.
	uint32_t cioCount;
} __attribute__((packed));

enum class CryptoFlags : uint32_t {
	// perform AES_GCM_128 crypto
	CryptoAES_GCM_128,
};

struct CryptoInfo {
	// pointer to the key material
	void * keyData;
	size_t keyDataLen;
	// flags that control how we do crypto
	CryptoFlags flags;
} __attribute__((packed));

}; // namespace AppleCIOMeshConfigUserClientInterface
