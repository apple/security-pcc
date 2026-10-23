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

#define kMaxNodes 8
#define kMaxChannels 8
#define kMaxChassisIdLength 32
#define kMaxHostnameLength 128

typedef struct MeshNodeInfo {
	uint8_t rank;
	uint8_t partitionIdx;
	int8_t inputChannel;
	uint8_t outputChannels[kMaxChannels];
	uint8_t outputChannelCount;
	char chassisId[kMaxChassisIdLength];
} MeshNodeInfo;

typedef struct MeshConnectedNodeInfo {
	MeshNodeInfo nodes[kMaxNodes];

	// The number of nodes connected;
	uint32_t nodeCount;
} MeshConnectedNodeInfo;

typedef struct PeerNodeInfo {
	uint32_t nodeId;
	char hostname[kMaxHostnameLength];
} PeerNodeInfo;

@interface AppleCIOMeshConfigServiceRef : NSObject

enum ConnectionDirection { TX, RX };

+ (NSArray<AppleCIOMeshConfigServiceRef *> *)all;

// Dispatch queue that async updates will be delivered on
// (re-)register notification blocks after calling this.
- (void)setDispatchQueue:(dispatch_queue_t)queue;

// Block to be executed when a mesh channel has connected/disconnected.
typedef void (^MeshChannelChangeBlock)(uint32_t channelIndex, uint32_t node, NSString * chassis, bool connected);
- (BOOL)onMeshChannelChange:(MeshChannelChangeBlock)block;

// Block to be executed when a connection to a node has changed.
typedef void (^NodeConnectionChangeBlock)(enum ConnectionDirection direction, uint32_t channelIndex, uint32_t node, bool connected);
- (BOOL)onNodeConnectionChange:(NodeConnectionChangeBlock)block;

// Block to be executed when a network connection to a node has changed.
typedef void (^NodeNetworkConnectionChangeBlock)(uint32_t node, bool connected);
- (BOOL)onNodeNetworkConnectionChange:(NodeNetworkConnectionChangeBlock)block;

// Block to be executed when a message arrives from a node.
typedef void (^NodeMessageBlock)(uint32_t node, NSData * message);
- (BOOL)onNodeMessage:(NodeMessageBlock)block;

// Sets the node id on the current node. This should be the node rank. This has
// to be set before activation.
- (BOOL)setExtendedNodeId:(uint32_t)nodeId;

// Sets the node id on the current node. This should be the node rank. This has
// to be set before activation.
- (BOOL)setNodeId:(uint32_t)nodeId;

// Gets the node id on the current node. This should be the node rank.
- (BOOL)getExtendedNodeId:(uint32_t *)nodeId;

// Sets the ensemble size
- (BOOL)setEnsembleSize:(uint32_t)ensembleSize;

// Get the size of the ensemble
- (BOOL)getEnsembleSize:(uint32_t *)ensembleSize;

// Gets the node id on the current node. This should be the node rank.
- (BOOL)getNodeId:(uint32_t *)nodeId;

// Gets the local node id on the current node.
- (BOOL)getLocalNodeId:(uint32_t *)nodeId;

- (NSMutableArray *)getPeerNodeRanks:(uint32_t)nodeId nodeCount:(uint32_t)nodeCount;

// Sets the chassis id on the current node. This has to be set before
// activation.
- (BOOL)setChassisId:(NSString *)chassisId;

// Set the hostnames of the current node's peers. This has to be set before activation.
- (BOOL)addPeerHostname:(NSString *)peerNodeHostname peerNodeId:(uint32_t)peerNodeId;

// Get the hostnames of the current node's peers.
- (NSArray *)getPeerHostnames;

// Activates the CIO mesh. The nodeId and the chassisId have to be set before
// activating the mesh as that is required for node discovery/publishing.
- (BOOL)activateCIO;

// Deactivate the CIO mesh. This will stop all pending transfers and all
// shared memory buffers will be destroyed. CIO will not longer be locked
// after deactivation.
- (BOOL)deactivateCIO;

// Locks CIO. Additional CIO Connections, and Mesh Connections will no longer
// be created. After locking, the only supported operation is to deactivate CIO.
- (BOOL)lockCIO;

// Is the CIO configuration locked?  Only once the mesh config is locked
// can we allow mesh clients to start communicating.
- (BOOL)isCIOLocked;

// Disconnects a CIO channel. The CIO channel can no longer be enabled
- (BOOL)disconnectCIOChannel:(uint32_t)channelIndex;

// Establish a transmit connection on a CIO channel. This must be called in
// order to send any data out from the node on the CIO channel. This includes
// forwarding another node's data on the channel. The connection is only
// established when the nodeConnectionChange comes back.
- (BOOL)establishTXConnection:(uint32_t)sourceNode onChannel:(uint32_t)channelIndex;

// Sends a control message to the destination node. Prior to setting this, there
// should be a route to that node.
- (BOOL)sendControlMessage:(NSData *)message toNode:(uint32_t)node;

// Gets hardware information from the driver.
- (BOOL)getHardwareState:(uint32_t *)linksPerChannel;

// Gets a list of all cio mesh connected nodes.
- (NSArray *)getConnectedNodes;

// Gets the raw list of cio mesh connected nodes.
- (BOOL)getConnectedNodesRaw:(MeshConnectedNodeInfo *)connectedNodes;

// Gets the CIO cable connectivity state
- (NSArray *)getCIOCableState;

// Sets the crypto key for all CIO Mesh data transfers using AppleCIOMesh APIs.
- (bool)setCryptoKey:(NSData *)keyData andFlags:(uint32_t)flags;

// Returns the crypto key used by AppleCIOMesh APIs.
- (NSData *)getCryptoKeyForSize:(size_t)keySize andFlags:(uint32_t *)flags;

// Returns the number of buffers that can be allocated per Crypto Key.
- (uint64_t)getMaxBuffersPerCryptoKey;

// Returns the number of buffers that can be allocated per Crypto Key.
- (uint64_t)getMaxSecondsPerCryptoKey;

// Returns the number of buffers allocated on the set Crypto Key.
- (uint64_t)getBuffersUsedForCryptoKey;

// Checks the number of XDomainLinks available in the IOregistry to see
// if the mesh can be activated
- (BOOL)canActivate:(uint32_t)nodeCount;

@end
