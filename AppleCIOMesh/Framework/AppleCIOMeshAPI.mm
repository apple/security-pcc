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

// Copyright 2021, Apple Inc. All rights reserved.

#include <AssertMacros.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <atomic>
#include <ctype.h>
#include <err.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/mach_vm.h>
#include <math.h>
#include <os/log.h>
#include <os/signpost_private.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <sysexits.h>
#include <unistd.h>

#import "PeerConnectionInfo.hpp"

extern "C" {
#include <corecrypto/cchkdf.h>
#include <corecrypto/ccmode.h>
}

#include <IOKit/IOKitLib.h>
#include <IOReport.h>

#include "AppleCIOMeshUserClientInterface.h"
#include "Arena.h"
#include "CFPrefsReader.h"
#include "Common/Config.h"
#include "Common/Handshake.h"
#import <AppleCIOMeshConfigSupport/AppleCIOMeshConfigSupport.h>
#import <AppleCIOMeshSupport/AppleCIOMeshAPI.h>
#import <AppleCIOMeshSupport/AppleCIOMeshAPIPrivate.h>
#import <AppleCIOMeshSupport/AppleCIOMeshSupport.h>
#import <MeshNetFramework/MeshNetFramework.h>
#include <pthread.h>

#define RECEIVEASSIGNED

#define USE_RT
// #define USE_YIELD
// #define USE_SLEEP_YIELD

#define kBytesPerGiga (1000000000)
#define kNsPerSecond (1000000000.0)
#define kUsPerSecond (1000000.0)

//
// Each frame in an NHI ring is a max of 4k and there are a max of 4096
// frames.  Thus we can't sendAndPrepare if 2x the buffer size is more
// than 16 megabytes.
//
#define kMaxSendAndPrepareSize (15 * 1024 * 1024)
#define kMaxBlockSize kMaxSendAndPrepareSize

// which direction to do the crypto operation
#define CRYPTO_ENCRYPT 1
#define CRYPTO_DECRYPT 2

// aes-gcm tag related define: this is the max number of tags that we could
// have in flight at any given time.
#define MAX_TAGS (kMaxCIOMeshNodes * MAX_CHUNKS_PER_BLOCK * kMaxMeshLinksPerChannel)

#define MESHLOG(fmt, ...) os_log_error(mh->stats.logHandle, fmt, ##__VA_ARGS__)
#define MESHLOG_STR(fmt) os_log_error(mh->stats.logHandle, fmt)
#define MESHLOGx printf
#define MESHLOG_DEFAULT(fmt, ...) os_log(mh->stats.logHandle, fmt, ##__VA_ARGS__)

#ifdef CHECK
#error "CHECK macro is already defined"
#else
#define CHECK(expr, msg, ...)            \
	do {                                 \
		if (!(expr)) {                   \
			MESHLOG(msg, ##__VA_ARGS__); \
			abort();                     \
		}                                \
	} while (false);

#define CHECKx(expr, msg, ...)                   \
	do {                                         \
		if (!(expr)) {                           \
			fprintf(stderr, msg, ##__VA_ARGS__); \
			abort();                             \
		}                                        \
	} while (false);
#endif

#define MAX_SPIN 10000000000ULL

// The amount of time to spin before creating CIOMesh realtime threads.
#define kWarmupSpinNs (50 * 1000 * 1000)

// A hack to get around the scheduler de-prioritizing realtime threads when we
// do not finish syncs in the constraints specified.
#define HACK_REALTIME_CONSTRAINT_MISS

#define kMeshBufferBlockSizeMultiple (128)

// MARK: - Configuration

static const CFStringRef DISABLE_RT_KEY      = CFSTR("disableRealtime");
static const CFStringRef CIOMESH_MODULE_NAME = CFSTR("com.apple.ciomesh");

// ABI checks
static_assert(offsetof(MeshBufferSet_t, bufferId) == 0, "ABI breakage");
static_assert(offsetof(MeshBufferSet_t, bufferSize) == 8, "ABI breakage");
static_assert(offsetof(MeshBufferSet_t, blockSize) == 16, "ABI breakage");
static_assert(offsetof(MeshBufferSet_t, chunkSize) == 24, "ABI breakage");
static_assert(offsetof(MeshBufferSet_t, bufferPtrs) == 32, "ABI breakage");
static_assert(offsetof(MeshBufferSet_t, numBuffers) == 40, "ABI breakage");
static_assert(offsetof(MeshBufferSet_t, nodeMask) == 48, "ABI breakage");
static_assert(offsetof(MeshBufferSet_t, sectionSize) == 56, "ABI breakage");
static_assert(offsetof(MeshBufferSet_t, mbs) == 64, "ABI breakage");

static_assert(offsetof(MeshExecPlan_t, mbs) == 0, "ABI breakage");
static_assert(offsetof(MeshExecPlan_t, maxReads) == 8, "ABI breakage");

static void
SyncStatsCircularQueue_enqueue(SyncStatsCircularQueue_t & circularQueue, const RecentSyncStats & syncStats)
{
	circularQueue.buffer[circularQueue.endIndex] = syncStats;
	circularQueue.endIndex                       = (circularQueue.endIndex + 1) % RECENT_SYNC_CAPACITY;

	if (circularQueue.count < RECENT_SYNC_CAPACITY) {
		circularQueue.count++;
	}
}

static void
SyncStatsCircularQueue_clear(SyncStatsCircularQueue_t & circularQueue)
{
	circularQueue.endIndex = 0;
	circularQueue.count    = 0;
}

// Returns true if the node is participating in the mask.
static bool
isNodeParticipating(uint32_t nodeRank, uint64_t mask)
{
	uint64_t value = 1ULL << nodeRank;
	return (mask & value) != 0;
}

// Array of all valid node masks
static const uint64_t all_masks[] = {
    0x0003,     0x0005,     0x0006,     0x0009,     0x000A,     0x000C,     0x000F,     0x0030,     0x0050,     0x0060,
    0x0090,     0x00A0,     0x00C0,     0x00F0,     0x00FF,     0x0101,     0x0202,     0x0300,     0x0404,     0x0500,
    0x0600,     0x0808,     0x0900,     0x0A00,     0x0C00,     0x0F00,     0x1010,     0x2020,     0x3000,     0x4040,
    0x5000,     0x6000,     0x8080,     0x9000,     0xA000,     0xC000,     0xF000,     0xFF00,     0xFFFF,     0x10001,
    0x10100,    0x20002,    0x20200,    0x30000,    0x40004,    0x40400,    0x50000,    0x60000,    0x80008,    0x80800,
    0x90000,    0xA0000,    0xC0000,    0xF0000,    0x100010,   0x101000,   0x200020,   0x202000,   0x300000,   0x400040,
    0x404000,   0x500000,   0x600000,   0x800080,   0x808000,   0x900000,   0xA00000,   0xC00000,   0xF00000,   0xFF0000,
    0xFF00FF,   0xFFFF00,   0x1000001,  0x1000100,  0x1010000,  0x2000002,  0x2000200,  0x2020000,  0x3000000,  0x4000004,
    0x4000400,  0x4040000,  0x5000000,  0x6000000,  0x8000008,  0x8000800,  0x8080000,  0x9000000,  0xA000000,  0xC000000,
    0xF000000,  0x10000010, 0x10001000, 0x10100000, 0x20000020, 0x20002000, 0x20200000, 0x30000000, 0x40000040, 0x40004000,
    0x40400000, 0x50000000, 0x60000000, 0x80000080, 0x80008000, 0x80800000, 0x90000000, 0xA0000000, 0xC0000000, 0xF0000000,
    0xFF000000, 0xFF0000FF, 0xFF00FF00, 0xFFFF0000, 0xFFFFFFFF};

// Returns true if the node mask is valid
static bool
isValidNodeMask(uint64_t nodeMask)
{
	for (uint64_t mask : all_masks) {
		if (nodeMask == mask) {
			return true;
		}
	}

	return false;
}

static void
populateMasks(MeshHandle_t * mh)
{
	static_assert(sizeof(all_masks) / sizeof(all_masks[0]) == MAX_NODE_MASKS, "Invalid mask count");

	for (uint64_t mask : all_masks) {
		if (!isNodeParticipating(mh->myNodeId, mask)) {
			continue;
		}
		mh->cryptoKeyArray.node_masks[mh->cryptoKeyArray.key_count] = mask;
		mh->cryptoKeyArray.key_count++;
	}
}

static AppleCIOMeshServiceRef *
getService(void)
{
	auto services = [AppleCIOMeshServiceRef all];

	if ([services count] == 0) {
		return NULL;
	}

	if ([services count] > 1) {
		MESHLOGx("Multiple services found, using first\n");
	}

	return [services objectAtIndex:0];
}

static AppleCIOMeshConfigServiceRef *
getConfigService(void)
{
	static AppleCIOMeshConfigServiceRef * confService = NULL;
	static dispatch_once_t pred;
	dispatch_once(&pred, ^{
	  auto services = [AppleCIOMeshConfigServiceRef all];

	  if ([services count] == 0) {
		  MESHLOGx("No config services found!\n");
	  } else {
		  if ([services count] > 1) {
			  MESHLOGx("Multiple config services found, using first\n");
		  }

		  confService = [services objectAtIndex:0];
	  }
	});
	return confService;
}

static SendToAllBuffer_t *
lookupSendToAllBuffer(MeshHandle_t * mh, uint64_t sendToAllBufferId)
{
	uint64_t numSendToAllBuffs = mh->sendToAllBuffers.arraySize;

	for (uint64_t i = 0; i < numSendToAllBuffs; i++) {
		if (mh->sendToAllBuffers.sendToAllBuffersArray[i].bufferId == sendToAllBufferId) {
			return &mh->sendToAllBuffers.sendToAllBuffersArray[i];
		}
	}

	return nullptr;
}

static MeshCryptoKeyState_t *
lookupKeyFromMask(MeshHandle_t * mh, uint64_t mask)
{
	if (mh->cryptoKeyArray.key_count > MAX_NODE_MASKS) {
		MESHLOG("Unexpected key count: %llu", mh->cryptoKeyArray.key_count);
		return NULL;
	}

	for (uint64_t i = 0; i < mh->cryptoKeyArray.key_count; i++) {
		if (mh->cryptoKeyArray.node_masks[i] == mask) {
			return &mh->cryptoKeyArray.keys[i];
		}
	}

	return NULL;
}

/// Gets node assignments from the CIOMesh driver. Caller is responsible for
/// freeing the output.
static MeshConnectedNodeInfo *
getAssignments(AppleCIOMeshConfigServiceRef * configService)
{
	MeshConnectedNodeInfo * connectedNodes;

	connectedNodes = (MeshConnectedNodeInfo *)calloc(sizeof(MeshConnectedNodeInfo), 1);
	if (connectedNodes == NULL) {
		return NULL;
	}

	if (![configService getConnectedNodesRaw:connectedNodes]) {
		return NULL;
	}

	return connectedNodes;
}

// Calculate the number of nodes participating in a mask.
static uint8_t
getNodeCountFromMask(uint64_t mask)
{
	return (uint8_t)__builtin_popcountll(mask);
}

static uint8_t
getPartitionCountFromMask(uint64_t mask)
{
	const uint8_t nodeCount = getNodeCountFromMask(mask);
	// If the number of nodes is not large enough for even a single partition, we still return 1 and treat it
	// as if it's a single partition. This makes the math flow the same way.
	if (nodeCount <= kMaxCIOMeshNodes) {
		return 1;
	}
	return nodeCount / kMaxCIOMeshNodes;
}

// Calculate the bit-mask of the nodes on the current partition [0..7], excluding self.
static uint8_t
calculateLocalNodeMask(uint64_t nodeMask, MeshHandle_t * mh, bool excludeSelf = true)
{
	if (excludeSelf) {
		nodeMask = nodeMask & ~(1ULL << mh->myNodeId);
	}
	nodeMask = nodeMask >> mh->partitionIdx * 8u;
	return (uint8_t)nodeMask;
}

// Returns the number of CIO connected nodes in the mask.
static uint8_t
getLocalNodeCountFromMask(uint64_t mask, uint8_t partitionIdx)
{
	auto localMask = (uint8_t)(mask >> partitionIdx * 8u);
	return (uint8_t)__builtin_popcountll(localMask);
}

// Calculates the offset in a buffer corresponding to given nodeRank within a mask.
// It does that by counting the bits set before the corresponding NodeRank bit in the mask.
//
// For example:
// In the mask 0b00001100 (2-node mask)
// The buffer offset for nodeRank=2 is 0
// The buffer offset for nodeRank=3 is 1
static uint8_t
getBufferOffsetForNode(uint64_t mask, uint32_t nodeRank)
{
	// set all the bits before the nodeRank's bit.
	uint64_t lowerBits = (1ull << nodeRank) - 1;

	// isolate the relevant bits and then count.
	return (uint8_t)__builtin_popcountll(mask & lowerBits);
}

// Calculates the Section offset (i.e. which section in the buffer) that belongs
// to the given partitionIdx.
// For example:
// In the mask 0xFF00FF (2 8n-partitions in a 32n ensemble)
// The section offset of partition 0 is 0
// The section offset of partition 2 is 1
// It's a logic error to pass a partition index that is not in the mask.
static uint8_t
getSectionOffsetForPartition(uint64_t nodeMask, uint8_t partitionIdx)
{
	uint64_t temp = 0xFFull << (partitionIdx * 8);
	CHECKx((temp & nodeMask) != 0, "Partitiong %u is not part of mask %llu\n", partitionIdx, nodeMask);

	if (getNodeCountFromMask(nodeMask) < kMaxCIOMeshNodes) {
		return 0;
	}

	uint8_t offset = 0;
	for (uint8_t pi = 0; pi <= partitionIdx; pi++) {
		uint64_t partitionMask = 0xFFull << (pi * 8);
		if ((partitionMask & nodeMask) == partitionMask)
			offset++;
	}
	return offset - 1;
}

// Calculates if a node with rank X is in the provided mask
static bool
isNodeInMask(uint64_t mask, uint32_t rank)
{
	rank = rank & 0xFF;
	return (1ull << rank) & mask;
}

// Quick & dirty check if we are in a p2p setup.
// It doesn't actually check if the nodes are proper peers (i.e. kMaxCIOMeshNodes apart).
static bool
isP2PMask(uint64_t nodeMask, uint8_t partitionIdx)
{
	auto localcount = getLocalNodeCountFromMask(nodeMask, partitionIdx);
	if (localcount != 1)
		return false;
	auto allcount = getNodeCountFromMask(nodeMask);
	if (allcount != 2)
		return false;
	return true;
}

static bool
areNetworkPeers(uint32_t nodeIdA, uint32_t nodeIdB)
{
	return nodeIdA % 8 == nodeIdB % 8;
}

extern "C" bool
MeshGetInfo(uint32_t * myNodeId, uint32_t * numNodesTotal)
{
	AppleCIOMeshConfigServiceRef * confService = getConfigService();

	*myNodeId      = (uint32_t)-1;
	*numNodesTotal = 0;

	if (!confService) {
		return false;
	}

	if (![confService getExtendedNodeId:myNodeId]) {
		return false;
	}

	MeshConnectedNodeInfo nodeInfo;
	if (![confService getConnectedNodesRaw:&nodeInfo]) {
		return false;
	}

	// the raw interface always says there are 8 nodes
	// and so we have to find the first one that has a
	// rank of 255 (aka -1) and then stop to find the
	// real number of nodes.
	uint32_t i;
	for (i = 0; i < nodeInfo.nodeCount; i++) {
		if (nodeInfo.nodes[i].rank == 255) {
			break;
		}
	}

	uint32_t extendedMesh = 0;
	NSArray * peers       = [confService getPeerHostnames];
	if (peers != nil) {
		// We have one peer in each partition.
		// Each partition has 8 nodes.
		extendedMesh = (uint32_t)peers.count * 8;
	}
	*numNodesTotal = i + extendedMesh;

	return true;
}

// Populates the ensemble map with the costs of transferring data from nodes
// within a 4 node chassis.
static void
PopulateChassisMap(MeshEnsembleMap_t * map, uint32_t chassisId, uint32_t nodesPerChassis)
{
	uint32_t nodeCount  = map->node_count;
	uint32_t start_node = chassisId * nodesPerChassis;

	// All nodes within a chassis are connected with CIO and require one CIO hop.
	for (uint32_t srcNode = start_node; srcNode < (start_node + nodesPerChassis); srcNode++) {
		for (uint32_t dstNode = start_node; dstNode < (start_node + nodesPerChassis); dstNode++) {
			if (srcNode != dstNode) {
				map->route_cost[srcNode * nodeCount + dstNode] = CioHop;
			}
		}
	}
}

// Populates the ensemble map with the costs of transferring data from
// nodes across chassis connected with CIO.
static void
PopulateInterChassisCIOMap(MeshEnsembleMap_t * map, uint32_t chassisId)
{
	uint32_t nodesPerChassis = 4;
	// starting node on chassis 0 or 2
	uint32_t startNodeSrc = chassisId * nodesPerChassis;
	// starting node on chassis 1 or 3
	uint32_t startNodeDst = (chassisId + 1) * nodesPerChassis;
	uint32_t nodeCount    = map->node_count;

	for (uint32_t srcNode = startNodeSrc; srcNode < (startNodeSrc + nodesPerChassis); srcNode++) {
		for (uint32_t dstNode = startNodeDst; dstNode < (startNodeDst + nodesPerChassis); dstNode++) {
			if (srcNode + nodesPerChassis == dstNode) {
				map->route_cost[srcNode * nodeCount + dstNode] = CioHop;
				map->route_cost[dstNode * nodeCount + srcNode] = CioHop;
			} else {
				map->route_cost[srcNode * nodeCount + dstNode] = 2 * CioHop;
				map->route_cost[dstNode * nodeCount + srcNode] = 2 * CioHop;
			}
		}
	}
}

// Populates the ensemble map with the costs of transferring data from nodes
// across the network, from partition 0 to partition 1.
static void
PopulateInterChassisNetworkMap(MeshEnsembleMap_t * map)
{
	uint32_t nodesPerEnsemble = 8;
	uint32_t startNodeSrc     = 0;
	uint32_t startNodeDst     = 8;
	uint32_t nodesPerChassis  = 4;
	uint32_t nodeCount        = map->node_count;

	// nodes from chassis 0 to nodes from partition 1 (chassis 2/3)
	for (uint32_t srcNode = startNodeSrc; srcNode < nodesPerChassis; srcNode++) {
		for (uint32_t dstNode = startNodeDst; dstNode < (startNodeDst + nodesPerEnsemble); dstNode++) {
			if (srcNode + nodesPerEnsemble == dstNode) {
				// source node has a direct network connection to destination node
				map->route_cost[srcNode * nodeCount + dstNode] = NetworkHop;
				map->route_cost[dstNode * nodeCount + srcNode] = NetworkHop;
			} else if (srcNode + nodesPerEnsemble + nodesPerChassis == dstNode) {
				// direct network connection to chassis 2 and direct cio connection to chassis 3
				map->route_cost[srcNode * nodeCount + dstNode] = NetworkHop + CioHop;
				map->route_cost[dstNode * nodeCount + srcNode] = NetworkHop + CioHop;
			} else if (dstNode / nodesPerChassis == 2) {
				// destination node is in chassis 2
				map->route_cost[srcNode * nodeCount + dstNode] = NetworkHop + CioHop;
				map->route_cost[dstNode * nodeCount + srcNode] = NetworkHop + CioHop;
			} else {
				// destination node is in chassis 3
				map->route_cost[srcNode * nodeCount + dstNode] = NetworkHop + (2 * CioHop);
				map->route_cost[dstNode * nodeCount + srcNode] = NetworkHop + (2 * CioHop);
			}
		}
	}

	// nodes from chassis 1 to nodes from partition 1 (chassis 2/3)
	startNodeSrc += nodesPerChassis;
	for (uint32_t srcNode = startNodeSrc; srcNode < startNodeSrc + nodesPerChassis; srcNode++) {
		for (uint32_t dstNode = startNodeDst; dstNode < (startNodeDst + nodesPerEnsemble); dstNode++) {
			if (srcNode + nodesPerEnsemble == dstNode) {
				// source node has a direct network connection to destination node
				map->route_cost[srcNode * nodeCount + dstNode] = NetworkHop;
				map->route_cost[dstNode * nodeCount + srcNode] = NetworkHop;
			} else if (srcNode + nodesPerChassis == dstNode) {
				// direct network connection to chassis 3 and direct cio connection to chassis 2
				map->route_cost[srcNode * nodeCount + dstNode] = NetworkHop + CioHop;
				map->route_cost[dstNode * nodeCount + srcNode] = NetworkHop + CioHop;
			} else if (dstNode / nodesPerChassis == 2) {
				// destination node is in chassis 2
				map->route_cost[srcNode * nodeCount + dstNode] = NetworkHop + (2 * CioHop);
				map->route_cost[dstNode * nodeCount + srcNode] = NetworkHop + (2 * CioHop);
			} else {
				// destination node is in chassis 3
				map->route_cost[srcNode * nodeCount + dstNode] = NetworkHop + CioHop;
				map->route_cost[dstNode * nodeCount + srcNode] = NetworkHop + CioHop;
			}
		}
	}
}

extern "C" MeshEnsembleMap_t *
MeshGetEnsembleMap(uint32_t nodeCount)
{
	MeshEnsembleMap_t * map = (MeshEnsembleMap_t *)calloc(1, sizeof(MeshEnsembleMap_t));
	if (map == NULL) {
		return NULL;
	}

	map->node_count = nodeCount;
	map->route_cost = (uint32_t *)calloc((nodeCount * nodeCount), sizeof(uint32_t));
	if (map->route_cost == NULL) {
		free(map);
		return NULL;
	}

	if (nodeCount == 2) {
		PopulateChassisMap(map, 0, 2);
	} else if (nodeCount == 4) {
		PopulateChassisMap(map, 0, 4);
	} else if (nodeCount == 8) {
		PopulateChassisMap(map, 0, 4);
		PopulateChassisMap(map, 1, 4);
		// populate costs for nodes between chassis 0 and 1
		PopulateInterChassisCIOMap(map, 0);
	} else if (nodeCount == 16) {
		PopulateChassisMap(map, 0, 4);
		PopulateChassisMap(map, 1, 4);
		PopulateChassisMap(map, 2, 4);
		PopulateChassisMap(map, 3, 4);
		// populate costs for routes between chassis 0 and 1
		PopulateInterChassisCIOMap(map, 0);
		// populate costs for routes between chassis 2 and 3
		PopulateInterChassisCIOMap(map, 2);
		// populate costs for routes needing the network
		PopulateInterChassisNetworkMap(map);
	} else {
		// invalid node count
		free(map->route_cost);
		free(map);
		return NULL;
	}

	return map;
}

extern "C" void
MeshFreeEnsembleMap(MeshEnsembleMap_t * map)
{
	if (map != NULL) {
		free(map->route_cost);
		map->route_cost = NULL;
		free(map);
	}
}

extern "C" uint32_t
MeshGetRouteCostForNodeRank(MeshEnsembleMap_t * map, uint32_t srcNode, uint32_t dstNode)
{
	if (map == NULL || map->route_cost == NULL) {
		return 0;
	}

	if ((srcNode * map->node_count + dstNode) < (map->node_count * map->node_count)) {
		return map->route_cost[srcNode * map->node_count + dstNode];
	}

	return 0;
}

extern "C" void
MeshSetVerbosity(MeshHandle_t * mh, uint32_t level)
{
	mh->verbose_level = level;
	MESHLOG_DEFAULT("Verbosity level is set to %d via API.", mh->verbose_level);
}

extern "C" uint64_t
MeshGetBufferOffsetForNode(MeshHandle_t * mh [[maybe_unused]], MeshBufferState_t * mbs, uint32_t nodeId)
{
	const auto nodeOffset = getBufferOffsetForNode(mbs->nodeMask, nodeId);
	return nodeOffset;
}

// MARK: - Crypto

// The tag should be 16 bytes
static int
aes_gcm_encrypt_memory(const void * key,
                       size_t keysz,
                       MeshCryptoIV * iv,
                       void * buf,
                       size_t amt,
                       void * obuf,
                       char * tag,
                       size_t tagsz,
                       uint32_t whoami)
{
	int cstat = 0;

	if (iv == NULL) {
		os_log_error(OS_LOG_DEFAULT, "IV pointer can't be NULL in aes_gcm_encrypt_memory() (whoami == %d)", whoami);
		return -1;
	} else if (iv->count == UINT32_MAX) {
		os_log_error(OS_LOG_DEFAULT, "gcm invocation limit hit in aes_gcm_encrypt_memory (%d)\n", whoami);
		return -1;
	}

	cstat = ccgcm_one_shot(ccaes_gcm_encrypt_mode(), keysz, key, sizeof(MeshCryptoIV), iv, 0, NULL, // additional data len + data
	                       amt, buf, obuf, // the amount of data, input buffer, output buffer
	                       tagsz, tag);    // tag len + data
	iv->count++;
	if (cstat != 0) {
		return -1;
	}

	return 0;
}

// The tag should be 16 bytes and come from the tag that was generated while encrypting
static int
aes_gcm_decrypt_memory(const void * key,
                       size_t keysz,
                       MeshCryptoIV * iv,
                       void * buf,
                       size_t amt,
                       void * obuf,
                       char * tag,
                       size_t tagsz,
                       uint32_t which_node,
                       uint32_t whoami)
{
	int cstat = 0;
	uint64_t orig_tag[2];
	memcpy(&orig_tag[0], tag, kTagSize);

	if (iv == NULL) {
		os_log_error(OS_LOG_DEFAULT, "IV pointer can't be NULL in aes_gcm_decrypt_memory() (whoami == %d)", whoami);
		return -1;
	} else if (iv->count == UINT32_MAX) {
		os_log_error(OS_LOG_DEFAULT, "gcm invocation limit hit in aes_gcm_decrypt_memory (%d)\n", whoami);
		return -1;
	}

	cstat = ccgcm_one_shot(ccaes_gcm_decrypt_mode(), keysz, key, sizeof(MeshCryptoIV), iv, 0, NULL, amt, buf,
	                       obuf,        // the amount of data, input buffer, output buffer
	                       tagsz, tag); // tag len + data

	if (cstat != 0) {
		os_log_error(OS_LOG_DEFAULT,
		             "Crypto[%d] Decrypt failed Node %d. cstat:%d amt:%zu input_tag:%llx-%llx decrypted_tag:%llx-%llx IV:%u\n",
		             whoami, which_node, cstat, amt, orig_tag[0], orig_tag[1], ((uint64_t *)&tag[0])[0], ((uint64_t *)&tag[0])[1],
		             iv->count);
	}

	return cstat;
}

static void
start_crypto_assigned_rx_threads(MeshHandle_t * mh, MeshBufferState_t * mbs, uint32_t bufferIdx)
{
	uint8_t cioNodeCount = getLocalNodeCountFromMask(mbs->nodeMask, mh->partitionIdx);
	atomic_fetch_add(&mh->crypto.assigned_reading_count, cioNodeCount - 1);

	for (int i = 0; i < MAX_CRYPTO_THREADS; i++) {
		if (mh->cryptoThreadArg[i].whoami_extended == (int)mh->myNodeId) {
			continue;
		}

		// also skip nodes that are not in the mask
		if (!isNodeInMask(mbs->nodeMask, mh->cryptoThreadArg[i].whoami_extended)) {
			continue;
		}

		atomic_store(&mh->crypto.assigned_bufferIdx[i], (int)bufferIdx);
		atomic_store(&mh->crypto.assigned_mbs[i], (uintptr_t)mbs);
	}
}

static bool
isRTDisabled()
{
	CFPropertyListRef val =
	    CFPreferencesCopyValue(DISABLE_RT_KEY, CIOMESH_MODULE_NAME, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);

	NSNumber * num = (NSNumber *)CFBridgingRelease(val);
	return [num boolValue];
}

static int
setThreadPolicy(MeshHandle_t * mh)
{
	if (isRTDisabled()) {
		return 0;
	}

#ifdef USE_RT
	// set ourselves for RT
	mach_timebase_info_data_t tb_info;
	mach_timebase_info(&tb_info);
	double ms_to_abs_time     = (static_cast<double>(tb_info.denom) / tb_info.numer) * 1000000;
	const double kTimeQuantum = 40;

	thread_time_constraint_policy_data_t rtPolicy;
	rtPolicy.period      = kTimeQuantum * ms_to_abs_time;
	rtPolicy.computation = kTimeQuantum * ms_to_abs_time;
	rtPolicy.constraint  = kTimeQuantum * ms_to_abs_time;
	rtPolicy.preemptible = 0;

	int ret;
	if ((ret = thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY,
	                             reinterpret_cast<thread_policy_t>(&rtPolicy), THREAD_TIME_CONSTRAINT_POLICY_COUNT)) !=
	    KERN_SUCCESS) {
		MESHLOG("%s: failed to set the real-time policy ret %d\n", __FUNCTION__, ret);
		return -1;
	}
#endif

	return 0;
}

// Calculates the chunk index in the chunkReceiveMap as well as the partition (i.e. section) index.
static uint64_t
calcChunkIndex(MeshHandle_t * mh,
               uint64_t blockOffset[kMaxPartitions],
               MeshBufferState_t * mbs,
               uint64_t receivedOffset,
               uint8_t * outPartitionIdx)
{
	const auto chunksPerBlock = mbs->blockSize / mbs->chunkSize;
	for (uint8_t i = 0; i < kMaxPartitions; i++) {
		if (blockOffset[i] > receivedOffset) {
			continue;
		}
		uint64_t index = (receivedOffset - blockOffset[i]) / mbs->chunkSize;
		if (index >= chunksPerBlock) {
			continue;
		}

		*outPartitionIdx = i;
		return index;
	}
	MESHLOG_STR("Failed to calculate chunk index. This should never happen.");
	abort();
}

static void *
crypto_thread_assigned_receive(void * arg)
{
	CryptoArg_t * cryptoArg  = (CryptoArg_t *)arg;
	MeshHandle_t * mh        = (MeshHandle_t *)cryptoArg->mh;
	uint32_t whoami_extended = cryptoArg->whoami_extended; // which node I am receiving from
	uint32_t whoami_local    = cryptoArg->whoami_local;

	int ret = setThreadPolicy(mh);
	if (ret == -1) {
		atomic_fetch_sub(&mh->num_threads, 1);
		return NULL;
	}

	semaphore_wait_signal(mh->threadInitGoSignal, mh->threadInitReadySignal);

	uint64_t numExpectedReceives;
	uint64_t chunksPerBlock;
	int64_t numReadRemaining;
	uint64_t inputBlockOffset[kMaxPartitions], outputBlockOffset[kMaxPartitions];
	uint64_t receivedOffsets[kMaxPartitions * MAX_TAGS / kMaxCIOMeshNodes];
	uint8_t chunkReceiveMap[kMaxPartitions * MAX_TAGS / kMaxCIOMeshNodes];

	uint64_t cryptoSize;
	atomic_int * cryptoUpdateCounter;
	atomic_uint_fast64_t * cryptoUpdateMask;
	MeshCryptoKeyState_t * keyState = nullptr;
	MeshBufferState_t * mbs         = nullptr;
	int readIdx;

	uintptr_t startReadBuffers = (uintptr_t)NULL;

	char tags[kMaxPartitions * MAX_TAGS / kMaxCIOMeshNodes][kTagSize];
	memset(&tags[0][0], 0xde, sizeof(tags));

	int64_t syncsToDo = 0;

#ifdef HACK_REALTIME_CONSTRAINT_MISS
	uint64_t rtGoTime = 0;
#endif

	while (atomic_load(&mh->reader_active) > 0) {
		if (syncsToDo == 0) {
			// Wait here for buffers to be assigned.
			atomic_fetch_add(&mh->reader_blocked, 1);
			// Wait on the specific signal for this thread.
			auto signalIndex = whoami_local;
			// printf("Waiting on signal %d\n", signalIndex);
			semaphore_wait(mh->threadSyncGoSignal[signalIndex]);
			// printf("Signal Index [%d] received a signal\n", signalIndex);

			atomic_fetch_sub(&mh->reader_blocked, 1);

#ifdef HACK_REALTIME_CONSTRAINT_MISS
			rtGoTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#endif

			// Set our syncs to perform here.
			syncsToDo = mh->pendingMaxReadAssign;

#ifdef DEBUG_SIGNPOSTS
			if (mh->verbose_level >= LogSignposts) {
				os_signpost_event_emit(mh->stats.logHandle, mh->stats.threadAliveSignpost, "threadAlive",
				                       "rxThread %u is alive to do %lld syncs", whoami_local, syncsToDo);
			}
#endif
		}

		// Wait for the prepare to be done, and we will be assigned a MBS
		// and bufferIdx

		while (true) {
			if (atomic_load(&mh->reader_active) == 0) {
				break;
			}

			if ((startReadBuffers = atomic_load(&mh->startReadChainedBuffers))) {
				break;
			}

			if (atomic_load(&mh->crypto.assigned_mbs[whoami_local]) != (uintptr_t)nullptr) {
				break;
			}

#ifdef HACK_REALTIME_CONSTRAINT_MISS
			uint64_t tmp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
			if (tmp - rtGoTime >= 25000000) {
				usleep(500);
				rtGoTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
			}
#endif
		}

		if (atomic_load(&mh->reader_active) == 0) {
			break;
		}

		// Read buffers need to be prepared/setup
		if (startReadBuffers != (uintptr_t)NULL) {
			// All receive threads are going to race for this, 1 will win the right
			// to do the first prepare and setup the readers
			if (!atomic_compare_exchange_strong(&mh->startReadChainedBuffers, &startReadBuffers, NULL)) {
				startReadBuffers = (uintptr_t)NULL;
				continue;
			}

			// I won the race to prepare read.
			MeshBufferState_t * readMBS = (MeshBufferState_t *)startReadBuffers;
			uint8_t cioNodeCount        = getLocalNodeCountFromMask(readMBS->nodeMask, mh->partitionIdx);
			const auto currentReadIdx   = atomic_load(&readMBS->currentReadIdx);
			if (cioNodeCount > 1) {
				// Wait for active read remaining to go to 0 to indicate all the previous
				// reads have been finished. We are now committing to do these reads.
				int64_t expectedReadRemaining = 0;
				while (!atomic_compare_exchange_strong(&readMBS->activeReadRemaining, &expectedReadRemaining, mh->readRemaining)) {
					expectedReadRemaining = 0;
				}
				mh->readRemaining = 0;

				// Do 1 prepare.
				if ([mh->service prepareAllIncomingTransferFor:readMBS->baseBufferId + currentReadIdx] == NO) {
					atomic_fetch_add(&readMBS->bufferInfo[currentReadIdx].performance.numErrs, 1);

					atomic_store(&mh->reader_active, 0);

					MESHLOG("prepare failed - bailing out of the reader (reader_active %d)\n", mh->reader_active);

					break;
				}
			}

			// Reset my startReadBuffers so I don't try to do this prepare again
			startReadBuffers = (uintptr_t)NULL;

			// Let all crypto threads know the bufferIdx and they are good to start
			// receiving
			start_crypto_assigned_rx_threads(mh, readMBS, currentReadIdx);

			continue;
		}

		// Sync to perform
		syncsToDo--;

		mbs     = (MeshBufferState_t *)atomic_exchange(&mh->crypto.assigned_mbs[whoami_local], 0);
		readIdx = atomic_load(&mh->crypto.assigned_bufferIdx[whoami_local]);

		keyState = mbs->assignedCryptoState;
		CHECK(keyState != nullptr, "No key generated for mask 0x%llx. Aborting", mbs->nodeMask);

		const auto partitionCount = getPartitionCountFromMask(mbs->nodeMask);

		{
			auto localMask         = calculateLocalNodeMask(mbs->nodeMask, mh, false /* excludeSelf */);
			const auto blockOffset = getBufferOffsetForNode(localMask, whoami_local);

			for (int i = 0; i < partitionCount; i++) {
				inputBlockOffset[i]  = mbs->blockSize * blockOffset + (i * mbs->sectionSize);
				outputBlockOffset[i] = mbs->userBlockSize * blockOffset + (i * mbs->userSectionSize);
			}

			// We still get perLink receives from the driver so that we can run both
			// links fast. We need to track when a full chunk has come in.
			numExpectedReceives = (mbs->blockSize / mbs->chunkSize) * mh->chunkDivider;
			numReadRemaining    = (int64_t)numExpectedReceives * partitionCount;
			chunksPerBlock      = (mbs->blockSize / mbs->chunkSize);

			memset(chunkReceiveMap, 0, sizeof(chunkReceiveMap) / sizeof(chunkReceiveMap[0]));

			cryptoSize          = mbs->userChunkSize;
			cryptoUpdateCounter = &mbs->bufferInfo[readIdx].chunkReceiveCount;
			cryptoUpdateMask    = &mbs->bufferInfo[readIdx].blockReceiveMask;

			char * srcPtr  = (char *)mbs->bufferInfo[readIdx].shadow;
			char * destPtr = (char *)mbs->bufferInfo[readIdx].bufferPtr;

			uint32_t currentIdx = 0;
			while (numReadRemaining > 0 && atomic_load(&mh->reader_active) > 0) {
				uint64_t receivedCount;

				if (keyState->crypto_key_sz == 0) {
					os_log_error(OS_LOG_DEFAULT, "No crypto key - bailing out of the reader\n");
					atomic_store(&mh->reader_active, 0);
					break;
				}

#ifdef HACK_REALTIME_CONSTRAINT_MISS
				// We could be looping for a while waiting for the next batch. This is a place we may need
				// to maintain our realtime priority while missing realtime constraints.
				uint64_t tmp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
				if (tmp - rtGoTime >= 25000000) {
					usleep(500);
					rtGoTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
				}
#endif

				bool ret = [mh->service waitOnNextBatchIncomingChunkOf:mbs->baseBufferId + (uint64_t)readIdx
				                                              fromNode:whoami_local
				                                         withBatchSize:(uint64_t)numReadRemaining
				                                     withReceivedCount:&receivedCount
				                                   withReceivedOffsets:&receivedOffsets[currentIdx]
				                                      withReceivedTags:&tags[currentIdx][0]];
				if (ret == false) {
					atomic_fetch_add(&mbs->bufferInfo[readIdx].performance.numErrs, 1);
					atomic_store(&mh->reader_active, 0);
					break;
				}
				// Go through all the offsets received, mark the receive map
				for (uint64_t i = 0; i < receivedCount; i++) {
					uint8_t pIdx             = 0;
					auto chunkIdxWithinBlock = calcChunkIndex(mh, inputBlockOffset, mbs, receivedOffsets[currentIdx + i], &pIdx);
					auto receiveMapChunkIdx  = (chunksPerBlock * pIdx) + chunkIdxWithinBlock;
					chunkReceiveMap[receiveMapChunkIdx]++;

					if (chunkReceiveMap[receiveMapChunkIdx] == mh->chunkDivider) {
						int err = 0;

						// Decrypt this chunk now that we received the full thing
						char * src  = &srcPtr[inputBlockOffset[pIdx] + (mbs->chunkSize * chunkIdxWithinBlock)];
						char * dest = &destPtr[outputBlockOffset[pIdx] + (mbs->userChunkSize * chunkIdxWithinBlock)];

						// The tags match on both links, so use the newly received subchunk
						// tag instead of the original offset, this way we can avoid an
						// unnecessary memcpy of the tags.
						char * tag = &tags[currentIdx + i][0];

						// In a single-partition mbs, the buffers we're decrypting are from are the nodes in the same
						// partition, so we use their extended_nodeId.
						//
						// However, in a multi-partition mbs, the buffers we're decrypting are from our local nodes AND
						// the network connected nodes. So, we determine the nodeId when we calculate the chunkIdx.
						// see the implementation of calcChunkIndex().
						const uint32_t targetNodeId =
						    partitionCount == 1 ? whoami_extended : whoami_local + (pIdx * kMaxCIOMeshNodes);

						auto baseIV          = keyState->crypto_node_iv[targetNodeId];
						auto originalIVCount = baseIV.count;
						baseIV.count         = originalIVCount + (uint32_t)chunkIdxWithinBlock;

						err = aes_gcm_decrypt_memory(keyState->crypto_key[targetNodeId], keyState->crypto_key_sz, &baseIV, src,
						                             cryptoSize, dest, tag, kTagSize, targetNodeId, whoami_extended);

						if (err != 0) {
							atomic_fetch_add(&mbs->bufferInfo[readIdx].performance.numErrs, 1);
							atomic_store(&mh->reader_active, 0);
							break;
						}

						if (err == 0) {
							uint64_t chunkIdx = (inputBlockOffset[pIdx] + (mbs->chunkSize * receiveMapChunkIdx)) / mbs->chunkSize;
							atomic_fetch_or(cryptoUpdateMask, (0x1) << chunkIdx);
							atomic_fetch_add(cryptoUpdateCounter, 1);
						}
					} // if (chunkReceiveMap[chunkIdx] == mh->chunkDivider)
				} // for (uint64_t i = 0; i < receivedCount; i++)

				currentIdx += receivedCount;
				numReadRemaining -= receivedCount;
			} // while (numReadRemaining > 0 && atomic_load(&mh->reader_active) > 0) {

			// Update all the crypto node IVs for all the partitions here.
			for (unsigned pIdx = mh->partitionIdx, sectionCtr = 0; sectionCtr < partitionCount;
			     sectionCtr++, pIdx                           = (pIdx + 1) % partitionCount) {
				uint32_t targetNodeId = whoami_local + (pIdx * kMaxCIOMeshNodes);
				keyState->crypto_node_iv[targetNodeId].count += (numExpectedReceives / mh->chunkDivider);
			}
		} // forech partition section

		if (atomic_load(&mbs->bufferInfo[readIdx].performance.numErrs) > 0) {
			break;
		}

		// Crypto thread is no longer reading
		uint8_t tmp = (uint8_t)atomic_fetch_sub(&mh->crypto.assigned_reading_count, 1);
#ifdef MESH_SKIP_LAST_GATHER_TIMESTAMP
		if (tmp > 2) {
			continue;
		} else if (tmp == 2) {
			atomic_store(&mh->useThisTimestamp, clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
			continue;
		} else if (tmp == 1) {
			// go on
		}
#else
		if (tmp != 1) {
			continue;
		}
#endif

		// I am last, let me prepare the next buffer.
		auto currentReadIdx = atomic_load(&mbs->currentReadIdx);
		auto nextReadIdx    = (currentReadIdx + 1) % mbs->numBuffers;
		while (!atomic_compare_exchange_weak(&mbs->currentReadIdx, &currentReadIdx, nextReadIdx)) {
			nextReadIdx = (currentReadIdx + 1) % mbs->numBuffers;
		}

		if (atomic_fetch_sub(&mbs->activeReadRemaining, 1) == 1) {
			// The full set of reads has been complete. let's just go back to spin.
			continue;
		}

		// There are more reads remaining, prepare the next buffer
		if ([mh->service prepareAllIncomingTransferFor:mbs->baseBufferId + nextReadIdx] == NO) {
			atomic_fetch_add(&mbs->bufferInfo[nextReadIdx].performance.numErrs, 1);

			atomic_store(&mh->reader_active, 0);

			MESHLOG("prepare failed - bailing out of the reader (reader_active %d)\n", mh->reader_active);

			break;
		}

		// Let all crypto threads know the bufferIdx and they are good to start
		// receiving
		start_crypto_assigned_rx_threads(mh, mbs, nextReadIdx);
	}

	atomic_fetch_sub(&mh->num_threads, 1);

	return NULL;
}

static void *
crypto_thread_assigned_encrypt(void * arg)
{
	CryptoArg_t * cryptoArg  = (CryptoArg_t *)arg;
	MeshHandle_t * mh        = (MeshHandle_t *)cryptoArg->mh;
	uint32_t whoami_local    = cryptoArg->whoami_local;
	uint32_t whoami_extended = cryptoArg->whoami_extended;

	int ret = setThreadPolicy(mh);
	if (ret == -1) {
		atomic_fetch_sub(&mh->num_threads, 1);
		return NULL;
	}

	semaphore_wait_signal(mh->threadInitGoSignal, mh->threadInitReadySignal);

	uint32_t numWrite;

	uint64_t inputCryptoSize, outputCryptoSize;
	atomic_int * cryptoUpdateCounter;
	MeshCryptoKeyState_t * keyState = nullptr;
	MeshBufferState_t * mbs         = nullptr;
	int bufferIdx                   = INT_MAX;

	int64_t syncsToDo = 0;
	uint8_t myGoIdx   = 0;

#ifdef HACK_REALTIME_CONSTRAINT_MISS
	uint64_t rtGoTime = 0;
#endif

	while (atomic_load(&mh->reader_active) > 0) {
		if (syncsToDo == 0) {
			// Wait here for buffers to be assigned.
			atomic_fetch_add(&mh->reader_blocked, 1);
			semaphore_wait_signal(mh->threadLeaderGoSignal[myGoIdx % THREAD_GO_SIGNAL_COUNT], mh->threadSyncWaitSignal);
			atomic_fetch_sub(&mh->reader_blocked, 1);

			// As the leader I have to wake up all the follower (decrypt) threads.
			// numThreads is equal to the nodeCount in the partition.
			// However, we only need to wake up the nodes participating in the mask (excluding self)
			auto nodeMask         = mh->pendingMBSAssignBuffer->nodeMask;
			auto localMask        = calculateLocalNodeMask(nodeMask, mh, true /* excludeSelf */);
			const auto numThreads = kMaxCIOMeshNodes;
			for (uint8_t i = 0; i < numThreads; i++) {
				const auto flag = (1u << i) & localMask;
				if (flag == 0) {
					// not participating
					continue;
				}
				const auto signalIndex = i;
				auto kr                = semaphore_signal(mh->threadSyncGoSignal[signalIndex]);
				if (kr != KERN_SUCCESS) {
					MESHLOG("Failed to signal follower thread sync go signal iter [%d].\n", i);
					atomic_fetch_sub(&mh->num_threads, 1);
					return NULL;
				}
			}

			myGoIdx++;

#ifdef HACK_REALTIME_CONSTRAINT_MISS
			rtGoTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#endif

			// Set our syncs to perform here.
			syncsToDo = mh->pendingMaxReadAssign;

#ifdef DEBUG_SIGNPOSTS
			if (mh->verbose_level >= LogSignposts) {
				os_signpost_event_emit(mh->stats.logHandle, mh->stats.threadAliveSignpost, "threadAlive",
				                       "txThread %u is alive to do %lld syncs", whoami_local, syncsToDo);
			}
#endif
		}

		// Wait for the prepare to be done, and we will be assigned a MBS
		// and bufferIdx
		while (true) {
			if (atomic_load(&mh->reader_active) == 0) {
				break;
			}

			if (atomic_load(&mh->pendingMBSAssignmentState) == StartAssignment) {
				break;
			}

			if (atomic_load(&mh->crypto.assigned_mbs[whoami_local]) != (uintptr_t)nullptr) {
				break;
			}

#ifdef HACK_REALTIME_CONSTRAINT_MISS
			uint64_t tmp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
			if (tmp - rtGoTime >= 25000000) {
				usleep(500);
				rtGoTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
			}
#endif
		}

		if (atomic_load(&mh->reader_active) == 0) {
			break;
		}

		// Do first prepare
		if (atomic_load(&mh->pendingMBSAssignmentState) == StartAssignment) {
			MeshBufferState_t * assigningMBS = mh->pendingMBSAssignBuffer;
			const uint8_t cioNodeCount       = getLocalNodeCountFromMask(assigningMBS->nodeMask, mh->partitionIdx);
			int64_t pendingReads             = mh->pendingMaxReadAssign;

			mh->readRemaining = pendingReads;
			atomic_store(&assigningMBS->firstPrepareDone, false);
			assigningMBS->syncRemaining = pendingReads;
			// Note: do not set activeReadRemaining here. It is used to control
			// all the reads, and will be set by the first reader that starts
			// the read chain.

			// Do not set execPlan's currentIdx either, that is managed by the reader
			// threads.

			// note that we assume this call is only made once, before the first
			// broadcast-and-gather. a value of zero means run forever
			if (cioNodeCount > 1) {
				if (assigningMBS->forwardChainId >= 0) {
					auto numSections      = getPartitionCountFromMask(assigningMBS->nodeMask);
					uint32_t forwardCount = ((uint32_t)assigningMBS->syncRemaining *
					                         (numSections * (uint32_t)assigningMBS->blockSize / (uint32_t)assigningMBS->chunkSize));

					if (![mh->service startForwardChain:(uint8_t)assigningMBS->forwardChainId forIteration:forwardCount]) {
						atomic_fetch_add(&mbs->bufferInfo[bufferIdx].performance.numErrs, 1);
						break;
					}
				}

				if (atomic_load(&assigningMBS->firstPrepareDone) == false) {
					if (![mh->service prepareAllOutgoingTransferFor:(assigningMBS->baseBufferId + assigningMBS->curBufferIdx)]) {
						atomic_fetch_add(&mbs->bufferInfo[bufferIdx].performance.numErrs, 1);
						break;
					}
					atomic_store(&assigningMBS->firstPrepareDone, true);
				}
			}
			// Start readers
			atomic_store(&mh->startReadChainedBuffers, (uintptr_t)assigningMBS);
			atomic_store(&mh->activateChainedBuffers, (uintptr_t)assigningMBS);

			// No more pending assignment
			atomic_store(&mh->pendingMBSAssignmentState, NoAssignment);

			continue;
		}

		// Sync encrypt

		syncsToDo--;

		mbs       = (MeshBufferState_t *)atomic_exchange(&mh->crypto.assigned_mbs[whoami_local], 0);
		bufferIdx = atomic_load(&mh->crypto.assigned_bufferIdx[whoami_local]);

		keyState = mbs->assignedCryptoState;

		CHECK(keyState != NULL, "No key found for this node mask 0x%llx, aborting.", mbs->nodeMask);

		numWrite = (mbs->blockSize / mbs->chunkSize);

		inputCryptoSize  = mbs->userChunkSize;
		outputCryptoSize = mbs->chunkSize;

		char * srcPtr  = (char *)mbs->bufferInfo[bufferIdx].bufferPtr;
		char * destPtr = (char *)mbs->bufferInfo[bufferIdx].shadow;

		cryptoUpdateCounter    = mh->crypto.assigned_chunk_encrypted;
		char * tagPtr          = (char *)atomic_load(&mh->crypto.assigned_encrypt_tag_ptr);
		const auto blockOffset = getBufferOffsetForNode(mbs->nodeMask, (uint8_t)whoami_extended);

		srcPtr += (blockOffset * mbs->userBlockSize);
		destPtr += (blockOffset * mbs->blockSize);

		for (uint64_t i = 0; i < numWrite; i++) {
			char * src  = &srcPtr[i * inputCryptoSize];
			char * dest = &destPtr[i * outputCryptoSize];

			int err = aes_gcm_encrypt_memory(keyState->crypto_key[whoami_extended], keyState->crypto_key_sz,
			                                 &keyState->crypto_node_iv[whoami_extended], src, inputCryptoSize, dest, tagPtr,
			                                 kTagSize, whoami_extended);
			if (err != 0) {
				atomic_fetch_add(&mbs->bufferInfo[bufferIdx].performance.numErrs, 1);
				break;
			}

			char * originalTagPtr = tagPtr;

			// Finished 1 tag,
			tagPtr += kTagSize;

			// Copy the tag into all links
			for (uint32_t t = 1; t < mh->chunkDivider; t++) {
				memcpy(tagPtr, originalTagPtr, kTagSize);
				tagPtr += kTagSize;
			}

			// Notify the broadcast thread we are done crypto for this chunk.
			atomic_fetch_add(cryptoUpdateCounter, mh->chunkDivider);

			// Go to the next update counter.
			cryptoUpdateCounter += 1;
		}

		// In a multi-partition ensemble, let's also decrypt the blocks received over the network for this node.
		const auto partitionCount = getPartitionCountFromMask(mbs->nodeMask);
		const bool p2pMask        = isP2PMask(mbs->nodeMask, mh->partitionIdx);
		if (!p2pMask && partitionCount == 1) {
			continue;
		}

		// Decryption of the net received sections for the current node.
		{
			if (p2pMask) {
				const auto numExpectedChunks = mbs->blockSize / mbs->chunkSize;
				uint32_t chunksProcessed     = 0;
				const auto peerNodeId        = mh->peerConnectionInfo[0].peerInfo.nodeId;
				const uint64_t blockOffset   = (uint64_t)getBufferOffsetForNode(mbs->nodeMask, (uint8_t)peerNodeId);
				auto inputBlockOffset        = mbs->blockSize * blockOffset;
				auto outputBlockOffset       = mbs->userBlockSize * blockOffset;
				auto * srcPtr                = (uint8_t *)mbs->bufferInfo[bufferIdx].shadow;
				auto * destPtr               = (uint8_t *)mbs->bufferInfo[bufferIdx].bufferPtr;
				srcPtr += inputBlockOffset;
				destPtr += outputBlockOffset;
				auto * receiveIV = &keyState->crypto_node_iv[peerNodeId];

				while (chunksProcessed < numExpectedChunks) {
					// Wait for network rx thread to receive the data and the tags for all sections.
					// Note: in p2p mode, we are using the variables of 'sections' to for 'chunks'.
					while (atomic_load(&mbs->bufferInfo[bufferIdx].sectionsReady) == chunksProcessed) {
						sched_yield();
					}

					const auto chunksReady = atomic_load(&mbs->bufferInfo[bufferIdx].sectionsReady) - chunksProcessed;

					for (unsigned i = 0; i < chunksReady; i++) {
						char * tag = mbs->bufferInfo[bufferIdx].netSectionRxTag[0][(uint32_t)chunksProcessed * mh->chunkDivider];
						auto encryptionError =
						    aes_gcm_decrypt_memory(keyState->crypto_key[peerNodeId], keyState->crypto_key_sz, receiveIV, srcPtr,
						                           mbs->userChunkSize, destPtr, (char *)tag, kTagSize, peerNodeId, peerNodeId);
						if (encryptionError != 0) {
							MESHLOG("Failed to decrypt received payload at chunkOffset: %d\n", chunksProcessed);
							atomic_fetch_add(&mbs->bufferInfo[bufferIdx].performance.numErrs, 1);
							atomic_store(&mh->reader_active, 0);
							break;
						}
						receiveIV->count++;
						srcPtr += mbs->chunkSize;
						destPtr += mbs->userChunkSize;
						chunksProcessed++;
					}
				}
				atomic_fetch_add(&mbs->bufferInfo[bufferIdx].net_sections_decrypted, 1);
			} else {
				const uint64_t expectedSectionsReady = partitionCount - 1;

				// Wait for network rx thread to receive the data and the tags for all sections.
				while (atomic_load(&mbs->bufferInfo[bufferIdx].sectionsReady) < expectedSectionsReady) {
					sched_yield();
				}

				const uint8_t participatingNodeCount = getNodeCountFromMask(mbs->nodeMask);
				if (participatingNodeCount > kMaxCIOMeshNodes) {
					CHECK(partitionCount == 2 || partitionCount == 4, "Unsupported partition count");

					auto * const src          = (uint8_t *)mbs->bufferInfo[bufferIdx].shadow;
					auto * const dest         = (uint8_t *)mbs->bufferInfo[bufferIdx].bufferPtr;
					const auto chunksPerBlock = mbs->blockSize / mbs->chunkSize;
					const auto localNodeId    = mh->myNodeId % kMaxCIOMeshNodes;

					// Networking will receive sections in myPartitionIdx+1, myPartitionIdx+2
					// and then loop around to myPartitionIdx-1.
					// It is important we decrypt in that order.
					// TODO(marco): Handle when partitions are not contiguous!!! e.g. 16n involving p0 and p3
					uint8_t pIdx = (mh->partitionIdx + 1) % partitionCount;
					for (uint8_t sectionCount = 1; sectionCount < partitionCount;
					     pIdx                 = (pIdx + 1) % partitionCount, sectionCount++) {
						auto peerNodeId        = pIdx * kMaxCIOMeshNodes + localNodeId;
						const auto blockOffset = getBufferOffsetForNode(mbs->nodeMask, peerNodeId);
						auto bufferOffset      = blockOffset * mbs->blockSize;
						auto * srcData         = src + bufferOffset;
						auto * dstData         = dest + blockOffset * mbs->userBlockSize;
						auto * keyState        = mbs->assignedCryptoState;
						for (uint64_t chk = 0; chk < chunksPerBlock; chk++) {
							char * tag = mbs->bufferInfo[bufferIdx].netSectionRxTag[sectionCount][chk * mh->chunkDivider];

							// printf("%d decrypting for bufferIdx %d, with tag:%llx-%llx.\n", chk, bufferIdx, ((uint64_t *)tag)[0],
							// ((uint64_t *)tag)[1]);
							auto err = aes_gcm_decrypt_memory(keyState->crypto_key[peerNodeId], keyState->crypto_key_sz,
							                                  &keyState->crypto_node_iv[peerNodeId], srcData, mbs->userChunkSize,
							                                  dstData, tag, kTagSize, peerNodeId, peerNodeId);

							if (err != 0) {
								atomic_fetch_add(&mbs->bufferInfo[bufferIdx].performance.numErrs, 1);
								atomic_store(&mh->reader_active, 0);
								break;
							}
							keyState->crypto_node_iv[peerNodeId].count++;
							srcData += mbs->chunkSize;
							dstData += mbs->userChunkSize;
						}
						atomic_fetch_add(&mbs->bufferInfo[bufferIdx].net_sections_decrypted, 1);
					}
				}
			}
		}
	}

	atomic_fetch_sub(&mh->num_threads, 1);
	return NULL;
}

static int
setNodeKeys(MeshHandle_t * mh, size_t meshCryptoKeyStateIdx, const void * key, size_t keysz)
{
	auto di                         = ccsha384_di();
	MeshCryptoKeyState_t * keyState = &mh->cryptoKeyArray.keys[meshCryptoKeyStateIdx];
	const uint64_t node_mask        = mh->cryptoKeyArray.node_masks[meshCryptoKeyStateIdx];

	char info[128];
	char iv_info[128];

	int info_size    = snprintf(info, sizeof(info), "key-derivation-%llu", node_mask);
	int iv_info_size = snprintf(iv_info, sizeof(iv_info), "IV-nonce-%llu", node_mask);

	if (info_size < 0 || iv_info_size < 0) {
		MESHLOG_STR("Error while formatting key/IV derivation strings");
		return -1;
	}

	for (uint32_t i = 0; i < kMaxExtendedMeshNodes; i++) {
		uint32_t tmp = i;
		int ret      = cchkdf(di, keysz, key, sizeof(tmp), &tmp, info_size, info, keysz, (void *)keyState->crypto_key[i]);
		if (ret != 0) {
			MESHLOG("Failed to generate broadcast key for node[%d]: %d\n", i, ret);
			return ret;
		}

		ret = cchkdf(di, keysz, key, sizeof(tmp), &tmp, iv_info_size, iv_info, sizeof(keyState->crypto_node_iv[i].prefix),
		             (void *)&keyState->crypto_node_iv[i].prefix);
		if (ret != 0) {
			MESHLOG("Failed to generate starting broadcast IV (%d)\n", ret);
			return ret;
		}
	}

	return 0;
}

extern "C" void
MeshSetCryptoKey(const void * key, size_t keysz)
{
	AppleCIOMeshConfigServiceRef * configService = nil;
	configService                                = getConfigService();
	if (configService) {
		uint32_t flags = 0;
		NSData * keyData;

		keyData = [[NSData alloc] initWithBytes:key length:keysz];
		if (![configService setCryptoKey:keyData andFlags:flags]) {
			MESHLOGx("Can't set crypto key!!\n");
		}
	} else {
		MESHLOGx("No ConfigService avaiable!!");
	}
}

// MARK: - Buffer Management

static int
connectBuffersToMesh(MeshHandle_t * mh, MeshBufferState_t * mbs, void ** bufferPtrs)
{
	uint32_t i;

	if (mh->cryptoKeyArray.key_count == 0) {
		os_log_error(OS_LOG_DEFAULT, "AppleCIOMesh: No crypto key set when allocating buffers\n");
		return EPERM;
	}

	for (i = 0; i < mbs->numBuffers; i++) {
		mbs->bufferInfo[i].bufferPtr   = bufferPtrs[i];
		mbs->bufferInfo[i].bufferSize  = mbs->bufferSize;
		mbs->bufferInfo[i].sectionSize = mbs->sectionSize;
		mbs->bufferInfo[i].blockSize   = mbs->blockSize;
		mbs->bufferInfo[i].chunkSize   = mbs->chunkSize;

		void * shadow = mh->shadow_arena->alloc(mbs->bufferSize);
		if (shadow == nullptr) {
			MESHLOG("AppleCIOMesh: failed to allocate shadow buffer at idx:%u.", i);
			goto fail;
		}
		mbs->bufferInfo[i].shadow = shadow;

		// allocate in kernel
		if (![mh->service allocateSharedMemory:(mbs->baseBufferId + i)
		                             atAddress:(mach_vm_address_t)mbs->bufferInfo[i].shadow
		                                ofSize:mbs->bufferSize
		                         withChunkSize:mbs->chunkSize
		                        withStrideSkip:0
		                       withStrideWidth:0
		                  withCommandBreakdown:mbs->forwardBreakdown]) {
			MESHLOG("AppleCIOMesh: failed to allocate buffer %u\n", i);
			goto fail;
		}
	}

	return 0;

fail:
	for (i = 0; i < mbs->numBuffers; i++) {
		if (mbs->bufferInfo[i].shadow != nullptr && mbs->bufferInfo[i].shadow != mbs->bufferInfo[i].bufferPtr) {
			mach_vm_deallocate(mach_task_self(), (mach_vm_address_t)mbs->bufferInfo[i].shadow, mbs->bufferSize);
		}
	}
	return ENOMEM;
}

// MARK: - Statistics

static void
update_stats(MeshHandle_t * mh, MeshBufferState_t * mbs)
{
	if (mh->verbose_level < LogStats) {
		return;
	}

	uint64_t diff;

#ifdef MESH_SKIP_LAST_GATHER_TIMESTAMP
	int ctr          = 0;
	uint64_t endTime = 0;
	while (atomic_load(&mh->useThisTimestamp) == 0) {
		if (ctr++ > 2000) {
			endTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
			break;
		}
	}

	if (endTime == 0) {
		endTime = atomic_exchange(&mh->useThisTimestamp, 0);
	}

	if (endTime < mbs->bufferInfo[mbs->curBufferIdx].performance.sendStartTime) {
		endTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
	}
#else
	uint64_t endTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#endif

	mh->stats.totalIncomingCounter++;
	mh->stats.averageIncomingCounter++;

	diff         = endTime - mbs->bufferInfo[mbs->curBufferIdx].performance.sendStartTime;
	double speed = mh->stats.incomingSize / ((double)diff / kNsPerSecond);

	if ((int64_t)diff > 0 && diff < mh->stats.syncMinTime) {
		mh->stats.syncMinTime = diff;
		mh->stats.syncMinIter = (int64_t)mbs->bufferInfo[mbs->curBufferIdx].performance.iterId;
	} else if (diff > mh->stats.syncMaxTime) {
		mh->stats.syncMaxTime = diff;
	}

	int i;
	for (i = 0; i < MESH_SYNC_HISTOGRAM_COUNT; i++) {
		// diff is in nsec so divide by 1000 for usec
		if ((diff / 1000) <= mh->stats.syncTimeHistogramBins[i]) {
			mh->stats.syncTimeHistogram[i]++;
			mbs->stats.syncTimeHistogram[i]++;
			break;
		}
	}

	if (i >= MESH_SYNC_HISTOGRAM_COUNT) {
		// throw it in the last bin
		mh->stats.syncTimeHistogram[MESH_SYNC_HISTOGRAM_COUNT - 1]++;
		mbs->stats.syncTimeHistogram[MESH_SYNC_HISTOGRAM_COUNT - 1]++;
	}
	// anything that falls in the last 3 bins counts as "long"
	if (i >= (MESH_SYNC_HISTOGRAM_COUNT - 3)) {
		os_signpost_event_emit(mh->stats.signpostHandle, mh->stats.longSyncSignpost, "longSync", "iteration %lld syncTime %lld",
		                       mbs->curIteration, diff);

		mbs->stats.largeTimes[mbs->stats.largeCounter]     = diff;
		mbs->stats.largeTimesIter[mbs->stats.largeCounter] = (uint64_t)mbs->bufferInfo[mbs->curBufferIdx].performance.iterId;
		if (++mbs->stats.largeCounter == LARGE_MAX_COUNTER) {
			mbs->stats.largeCounter = 0;
		}
	}

	mh->stats.syncTotalTime += diff;
	mh->stats.syncCounter++;
	speed = mh->stats.outgoingSize / ((double)diff / kNsPerSecond);
	mh->stats.averageOutgoingSpeed =
	    ((mh->stats.averageOutgoingSpeed * mh->stats.totalOutgoingCounter) + speed) / (mh->stats.totalOutgoingCounter + 1);
	mh->stats.totalOutgoingCounter++;
	mh->stats.averageOutgoingCounter++;

	mbs->stats.syncTotalTime += diff;
	mbs->stats.syncCounter++;

	RecentSyncStats_t syncStats;
	syncStats.syncTime   = diff;
	syncStats.bufferSize = mbs->bufferSize;
	syncStats.nodeMask   = mbs->nodeMask;
	syncStats.endTime    = endTime;
	SyncStatsCircularQueue_enqueue(mh->stats.recentSyncs, syncStats);

	// MBS histogram done with MH
}

void
MeshLogStats(MeshHandle_t * mh, uint64_t numSyncs)
{
	if (numSyncs > mh->stats.recentSyncs.count) {
		numSyncs = mh->stats.recentSyncs.count;
	}
	MESHLOG_DEFAULT("Showing stats for last %llu syncs.", numSyncs);
	const uint64_t startIdx = (mh->stats.recentSyncs.endIndex + RECENT_SYNC_CAPACITY - numSyncs) % RECENT_SYNC_CAPACITY;

	for (uint64_t i = 0; i < numSyncs; i++) {
		uint64_t index                = startIdx + i;
		RecentSyncStats_t & syncStats = mh->stats.recentSyncs.buffer[index];
		MESHLOG_DEFAULT("Sync %llu, bufferSize: %lld, node mask: 0x%llx, duration: %lluns, timestamp: %llu", i,
		                syncStats.bufferSize, syncStats.nodeMask, syncStats.syncTime, syncStats.endTime);
	}

	SyncStatsCircularQueue_clear(mh->stats.recentSyncs);
}

// MARK: - Thread Management

extern "C" void
MeshStartReaders(__unused MeshHandle_t * mh)
{
	// Do nothing
}

static void *
netSendMultiPartition(void * arg)
{
	auto * cryptoArg        = (CryptoArg_t *)arg;
	auto * mh               = (MeshHandle_t *)cryptoArg->mh;
	int64_t syncsToDo       = 0;
	MeshBufferState_t * mbs = nullptr;
	uint32_t bufferIdx      = 0;

	while (atomic_load(&mh->reader_active) > 0) {
		if (syncsToDo == 0) {
			// Wait here for buffers to be assigned.
			atomic_fetch_add(&mh->reader_blocked, 1);
			// Wait on the specific signal for this thread.
			semaphore_wait(mh->netSendMultiPartitionGoSignal);
			atomic_fetch_sub(&mh->reader_blocked, 1);

			// Pull the MBS that was assigned to me and see if I need to be active
			mbs = (MeshBufferState_t *)atomic_load(&mh->crypto.assigned_mbs_net);

			syncsToDo = atomic_load(&mh->crypto.assigned_syncCount_net);
			bufferIdx = atomic_load(&mh->crypto.assigned_bufferIdx_net);
		}

		auto * sendPtr = (uint8_t *)mbs->bufferInfo[bufferIdx].shadow;

		// Find the block that my node is supposed to be sending.
		const auto blockOffset = getBufferOffsetForNode(mbs->nodeMask, (uint8_t)mh->myNodeId);
		auto sendBlockOffset   = mbs->blockSize * blockOffset;

		sendPtr += sendBlockOffset;
		auto * const blockStartPtr = sendPtr;

		// Calculate how many chunks we will be sending.
		const auto chunksPerBlock = mbs->blockSize / mbs->chunkSize;
		const auto partitionCount = getPartitionCountFromMask(mbs->nodeMask);
		uint8_t pIdx              = (mh->partitionIdx - 1) % partitionCount;
		for (uint8_t sectionCtr = 1; sectionCtr < partitionCount; pIdx = (pIdx - 1) % partitionCount, sectionCtr++) {
			sendPtr                                     = blockStartPtr;
			AppleCIOMeshNet::TcpConnection & connection = mh->peerConnectionInfo[0].tx_connection.value();
			for (uint64_t i = 0; i < chunksPerBlock; i++) {
				uint8_t * tagbits = nullptr;
				while (atomic_load(&mh->reader_active) > 0) {
					// TODO(32n): needs to be per section i.e. net_tx_tag_ptr[sectionCtr][i]
					tagbits = (uint8_t *)atomic_exchange(&mh->crypto.net_tx_tag_ptr[i], 0);
					if (tagbits != nullptr) {
						break;
					}
				}

				const auto [written, err] = connection.write(sendPtr, mbs->chunkSize);
				if (written < 0) {
					MESHLOG("Failed to send payload to network. Error: %s\n", strerror(err));
					atomic_store(&mh->reader_active, 0);
					break;
				}
				if (written == 0) {
					MESHLOG("Peer disconnected unexpectedly.");
					atomic_store(&mh->reader_active, 0);
					break;
				}

				// Write the tag
				const auto [tagWritten, tagErr] = connection.write(tagbits, kTagSize);
				if (tagWritten < 0) {
					MESHLOG("Failed to send tag to network. Error: %s\n", strerror(tagErr));
					atomic_store(&mh->reader_active, 0);
					break;
				}
				if (tagWritten == 0) {
					MESHLOG("Peer disconnected unexpectedly.");
					atomic_store(&mh->reader_active, 0);
					break;
				}
				// printf("%d - Sent chunk for bufferIdx %d & tag: %llx-%llx\n", i, bufferIdx, ((uint64_t *)tagbits)[0], ((uint64_t
				// *)tagbits)[1]);
				sendPtr += mbs->chunkSize;
				atomic_fetch_add(&mbs->net_broadcast_chunk_count, 1);
			}
		}
		syncsToDo--;
		bufferIdx = (bufferIdx + 1) % mbs->numBuffers;
	}
	return nullptr;
}

static void *
sendToNetworkPeer(void * arg)
{
	auto * cryptoArg          = (CryptoArg_t *)arg;
	auto * mh                 = (MeshHandle_t *)cryptoArg->mh;
	int64_t syncsToDo         = 0;
	const uint32_t peerNodeId = mh->peerConnectionInfo[0].peerInfo.nodeId;
	MeshBufferState_t * mbs   = nullptr;
	uint32_t bufferIdx        = 0;

	while (atomic_load(&mh->reader_active) > 0) {
		if (syncsToDo == 0) {
			// Wait here for buffers to be assigned.
			atomic_fetch_add(&mh->reader_blocked, 1);
			// Wait on the specific signal for this thread.
			semaphore_wait(mh->netSendPeerGoSignal);
			atomic_fetch_sub(&mh->reader_blocked, 1);

			// Pull the MBS that was assigned to me and see if I need to be active
			mbs = (MeshBufferState_t *)atomic_load(&mh->crypto.assigned_mbs_net);

			// check if the current MeshBufferState mask involves a network peer.
			if (!isNodeInMask(mbs->nodeMask, mh->myNodeId) || !isNodeInMask(mbs->nodeMask, peerNodeId)) {
				// This peer is not involved in the current buffer, so skip it.
				continue;
			}
			syncsToDo = atomic_load(&mh->crypto.assigned_syncCount_net);
			bufferIdx = atomic_load(&mh->crypto.assigned_bufferIdx_net);
		}

		auto * sendPtr = (uint8_t *)mbs->bufferInfo[bufferIdx].shadow;

		// Find the block that my node is supposed to be sending.
		const auto blockOffset = getBufferOffsetForNode(mbs->nodeMask, (uint8_t)mh->myNodeId);
		auto sendBlockOffset   = (mbs->blockSize * (uint64_t)blockOffset);

		sendPtr += sendBlockOffset;

		// Calculate how many chunks we will be sending.
		const auto numExpectedWrites = mbs->blockSize / mbs->chunkSize;

		for (uint64_t i = 0; i < numExpectedWrites; i++) {
			const uint8_t * tagbits = nullptr;

			while (atomic_load(&mh->reader_active) > 0) {
				tagbits = (uint8_t *)atomic_exchange(&mh->crypto.net_tx_tag_ptr[i], 0);
				if (tagbits != nullptr)
					break;
			}

			AppleCIOMeshNet::TcpConnection & connection = mh->peerConnectionInfo[0].tx_connection.value();
			const auto [written, err]                   = connection.write(sendPtr, mbs->chunkSize);
			if (written < 0) {
				MESHLOG("Failed to send payload to network. Error: %s\n", strerror(err));
				atomic_store(&mh->reader_active, 0);
				break;
			}
			if (written == 0) {
				MESHLOGx("Peer disconnected unexpectedly.");
				atomic_store(&mh->reader_active, 0);
				break;
			}
			// Write the tag
			const auto [tagWritten, tagErr] = connection.write(tagbits, kTagSize);
			if (tagWritten < 0) {
				MESHLOGx("Failed to send tag to network. Error: %s\n", strerror(tagErr));
				atomic_store(&mh->reader_active, 0);
				break;
			}
			if (tagWritten == 0) {
				MESHLOGx("Peer disconnected unexpectedly.");
				atomic_store(&mh->reader_active, 0);
				break;
			}

			sendPtr += mbs->chunkSize;
			atomic_fetch_add(&mbs->net_broadcast_chunk_count, 1);
		}

		syncsToDo--;
		bufferIdx = (bufferIdx + 1) % mbs->numBuffers;
	}

	return nullptr;
}

// runs during BaG on network-extended ensemble.
static void *
netReceiveMultiPartition(void * arg)
{
	MeshHandle_t * mh       = (MeshHandle_t *)arg;
	MeshBufferState_t * mbs = nullptr;
	int64_t syncsToDo       = 0;
	uint32_t bufferIdx      = 0;
	while (atomic_load(&mh->reader_active) > 0) {
		if (syncsToDo == 0) {
			// Wait here for buffers to be assigned.
			atomic_fetch_add(&mh->reader_blocked, 1);
			// Wait on the specific signal for this thread.
			auto kr = semaphore_wait(mh->netReceiveMultiPartitionGoSignal);
			if (kr != KERN_SUCCESS) {
				MESHLOG("Failed to wait for receive multi-partition signal");
				return nullptr;
			}
			atomic_fetch_sub(&mh->reader_blocked, 1);

			// Pull the MBS that was assigned to me and see if I need to be active
			mbs       = (MeshBufferState_t *)atomic_load(&mh->crypto.assigned_mbs_net);
			syncsToDo = atomic_load(&mh->crypto.assigned_syncCount_net);
			bufferIdx = atomic_load(&mh->crypto.assigned_bufferIdx_net);
		}

		while (true) {
			if (atomic_load(&mh->reader_active) == 0) {
				break;
			}

			if (atomic_load(&mbs->bufferInfo[bufferIdx].sectionsReady) == 0) {
				break;
			}
			sched_yield();
		}

		if (atomic_load(&mh->reader_active) == 0) {
			break;
		}

		atomic_int * cryptoUpdateCounter        = &mbs->bufferInfo[bufferIdx].chunkReceiveCount;
		atomic_uint_fast64_t * cryptoUpdateMask = &mbs->bufferInfo[bufferIdx].blockReceiveMask;
		const auto partitionCount               = getPartitionCountFromMask(mbs->nodeMask);
		const auto chunksPerBlock               = (mbs->blockSize / mbs->chunkSize);
		auto * const shadow                     = (uint8_t *)mbs->bufferInfo[bufferIdx].shadow;
		uint8_t pIdx                            = (mh->partitionIdx + 1) % partitionCount;
		for (uint8_t sectionCount = 1; sectionCount < partitionCount; pIdx = (pIdx + 1) % partitionCount, sectionCount++) {
			// TODO (marco 32n): Make sure the order of the connection peers in the array is the same as the receive order.
			auto peerNodeId                             = mh->peerConnectionInfo[0].peerInfo.nodeId;
			AppleCIOMeshNet::TcpConnection & connection = mh->peerConnectionInfo[0].rx_connection.value();
			CHECK(peerNodeId == (pIdx * kMaxCIOMeshNodes + mh->myNodeId % kMaxCIOMeshNodes),
			      "Error: Network connections order is different from receive order");
			const auto blockOffset = getBufferOffsetForNode(mbs->nodeMask, peerNodeId);
			auto bufferOffset      = blockOffset * mbs->blockSize;
			auto * dst             = shadow + bufferOffset;
			for (uint64_t chk = 0; chk < chunksPerBlock; chk++) {
				const auto [chunkRead, chunkErr] = connection.read(dst, mbs->chunkSize);
				if (chunkRead < 0) {
					MESHLOG("Failed to receive payload from network. Error: %s\n", strerror(chunkErr));
					atomic_store(&mh->reader_active, 0);
					return nullptr;
				}

				if (chunkRead == 0) {
					MESHLOGx("Peer disconnected unexpectedly.");
					atomic_store(&mh->reader_active, 0);
					return nullptr;
				}

				// receive the tag
				uint8_t tagBuffer[kTagSize];
				const auto [tagRead, tagErr] = connection.read(tagBuffer, kTagSize);
				if (tagRead < 0) {
					MESHLOG("Failed to receive tag from network: Error: %s\n", strerror(tagErr));
					atomic_store(&mh->reader_active, 0);
					return nullptr;
				}
				if (tagRead == 0) {
					MESHLOGx("Peer disconnected unexpectedly.");
					atomic_store(&mh->reader_active, 0);
					return nullptr;
				}

				// printf("%d received bufferIdx %d tag:%llx-%llx.\n", chk, bufferIdx, ((uint64_t *)tagBuffer)[0], ((uint64_t
				// *)tagBuffer)[1]);
				memcpy(mbs->bufferInfo[bufferIdx].netSectionRxTag[sectionCount][chk * mh->chunkDivider + 0], tagBuffer, kTagSize);
				memcpy(mbs->bufferInfo[bufferIdx].netSectionRxTag[sectionCount][chk * mh->chunkDivider + 1], tagBuffer, kTagSize);
				dst += mbs->chunkSize;

				uint64_t chunkIdx = (blockOffset + (mbs->chunkSize * chk)) / mbs->chunkSize;
				atomic_fetch_or(cryptoUpdateMask, (0x1) << chunkIdx);
				atomic_fetch_add(cryptoUpdateCounter, 1);
			}

			atomic_fetch_add(&mbs->bufferInfo[bufferIdx].sectionsReady, 1);
			// printf("Sections ready is %d for bufferId: %d\n", prev + 1, bufferIdx);
		}

		bufferIdx = (bufferIdx + 1) % mbs->numBuffers;
		syncsToDo--;
	}

	return nullptr;
}

static void *
receiveFromNetworkPeer(void * arg)
{
	auto * cryptoArg                = (CryptoArg_t *)arg;
	auto * mh                       = (MeshHandle_t *)cryptoArg->mh;
	const uint32_t peerNodeId       = mh->peerConnectionInfo[0].peerInfo.nodeId;
	int64_t syncsToDo               = 0;
	MeshBufferState_t * mbs         = nullptr;
	uint32_t bufferIdx              = 0;
	MeshCryptoKeyState_t * keyState = nullptr;

	while (atomic_load(&mh->reader_active) > 0) {
		if (syncsToDo == 0) {
			// Wait here for buffers to be assigned.
			atomic_fetch_add(&mh->reader_blocked, 1);
			// Wait on the specific signal for this thread.
			semaphore_wait(mh->netReceivePeerGoSignal);

			atomic_fetch_sub(&mh->reader_blocked, 1);

#ifdef HACK_REALTIME_CONSTRAINT_MISS
			// uint64_t rtGoTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
#endif

			// Pull the MBS that was assigned to me and see if I need to be active
			mbs = (MeshBufferState_t *)atomic_load(&mh->crypto.assigned_mbs_net);

			// check if the current MeshBufferState mask involves a network peer.
			if (!isNodeInMask(mbs->nodeMask, mh->myNodeId) || !isNodeInMask(mbs->nodeMask, peerNodeId)) {
				// This peer is not involved in the current buffer, so skip it.
				continue;
			}
			keyState = mbs->assignedCryptoState;
			CHECK(keyState != nullptr, "No key generated for mask 0x%llx. Aborting", mbs->nodeMask);
			syncsToDo = atomic_load(&mh->crypto.assigned_syncCount_net);
			bufferIdx = atomic_load(&mh->crypto.assigned_bufferIdx_net);
		}

		auto numExpectedReceives = (mbs->blockSize / mbs->chunkSize);

		const uint64_t blockOffset = (uint64_t)getBufferOffsetForNode(mbs->nodeMask, (uint8_t)peerNodeId);

		auto inputBlockOffset  = mbs->blockSize * blockOffset;
		auto outputBlockOffset = mbs->userBlockSize * blockOffset;

		auto * srcPtr                               = (uint8_t *)mbs->bufferInfo[bufferIdx].shadow;
		auto * destPtr                              = (uint8_t *)mbs->bufferInfo[bufferIdx].bufferPtr;
		AppleCIOMeshNet::TcpConnection & connection = mh->peerConnectionInfo[0].rx_connection.value();
		uint8_t tag[kTagSize]                       = {0};

		atomic_int * cryptoUpdateCounter        = &mbs->bufferInfo[bufferIdx].chunkReceiveCount;
		atomic_uint_fast64_t * cryptoUpdateMask = &mbs->bufferInfo[bufferIdx].blockReceiveMask;

		srcPtr += inputBlockOffset;
		destPtr += outputBlockOffset;

		for (uint32_t i = 0; i < numExpectedReceives; i++) {
			const auto [chunkRead, chunkErr] = connection.read(srcPtr, mbs->chunkSize);
			if (chunkRead < 0) {
				MESHLOG("Failed to receive payload from network. Error: %s\n", strerror(chunkErr));
				atomic_store(&mh->reader_active, 0);
				return nullptr;
			}
			if (chunkRead == 0) {
				MESHLOGx("Peer disconnected unexpectedly.");
				atomic_store(&mh->reader_active, 0);
				return nullptr;
			}

			// receive the tag
			const auto [tagRead, tagErr] = connection.read(tag, kTagSize);
			if (tagRead < 0) {
				MESHLOG("Failed to receive tag from network: Error: %s\n", strerror(tagErr));
				atomic_store(&mh->reader_active, 0);
				return nullptr;
			}
			if (tagRead == 0) {
				MESHLOGx("Peer disconnected unexpectedly.");
				atomic_store(&mh->reader_active, 0);
				return nullptr;
			}

			// Copy the tags so we can decrypt the chunks asynchronously as they come in without blocking the socket
			// reads.
			// Note: we are using the variables of 'sections' to for 'chunks'.
			memcpy(mbs->bufferInfo[bufferIdx].netSectionRxTag[0][i * mh->chunkDivider], tag, kTagSize);

			uint64_t chunkIdx = (inputBlockOffset + (mbs->chunkSize * i)) / mbs->chunkSize;
			atomic_fetch_or(cryptoUpdateMask, (0x1) << chunkIdx);
			atomic_fetch_add(cryptoUpdateCounter, 1);

			srcPtr += mbs->chunkSize;
			destPtr += mbs->userChunkSize;
			atomic_fetch_add(&mbs->bufferInfo[bufferIdx].sectionsReady, 1);
		}

		bufferIdx = (bufferIdx + 1) % mbs->numBuffers;

		// We need to update mbs->currentReadIdx since p2p does not involve CIO threads. Normally when CIO threads
		// are involved, the last decryption thread advances this variable.
		auto currentReadIdx = atomic_load(&mbs->currentReadIdx);
		auto nextReadIdx    = (currentReadIdx + 1) % mbs->numBuffers;
		while (!atomic_compare_exchange_weak(&mbs->currentReadIdx, &currentReadIdx, nextReadIdx)) {
			nextReadIdx = (currentReadIdx + 1) % mbs->numBuffers;
		}
		syncsToDo--;

	} // while (atomic_load(&mh->reader_active) > 0) {

	return nullptr;
}

static bool
StartReaders_Private(MeshHandle_t * mh)
{
	bool activationRequired = atomic_fetch_add(&mh->reader_active, 1) == 0;
	if (!activationRequired) {
		return true;
	}

	// ramp up to P core to ensure we don't schedule new threads on Ecores.
	// Spin for 50ms
	if (!mh->warmupDone) {
		uint64_t start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
		while ((clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) < kWarmupSpinNs) {}

		mh->warmupDone = true;
	}

	uint8_t numThreads = mh->localNodeCount;

	for (uint32_t x = 0; x < numThreads; x++) {
		uint32_t nodeIdForThread = x + (mh->partitionIdx * 8);

		atomic_fetch_add(&mh->num_threads, 1);

		mh->cryptoThreadArg[x].mh              = mh;
		mh->cryptoThreadArg[x].whoami_local    = x;
		mh->cryptoThreadArg[x].whoami_extended = nodeIdForThread;

		{
			pthread_attr_t threadAttributes;
			int error = pthread_attr_init(&threadAttributes);
			if (error) {
				MESHLOG_STR("Failed to initialize pthread attributes");
				return false;
			}

			sched_param schedulingParams;
			error = pthread_attr_getschedparam(&threadAttributes, &schedulingParams);
			if (error) {
				MESHLOG_STR("Failed to get pthread scheduler param");
				return false;
			}

			schedulingParams.sched_priority = 61;
			error                           = pthread_attr_setschedparam(&threadAttributes, &schedulingParams);
			if (error) {
				MESHLOG_STR("Failed to set pthread scheduler param");
				return false;
			}

			error = pthread_attr_setschedpolicy(&threadAttributes, SCHED_RR);
			if (error) {
				MESHLOG_STR("Failed to set pthread scheduler policy to RR");
				return false;
			}

			auto cryptoFunction = &crypto_thread_assigned_receive;
			if (nodeIdForThread == mh->myNodeId) {
				cryptoFunction = &crypto_thread_assigned_encrypt;
			}

			pthread_create(&mh->cryptoThreads[x], &threadAttributes, cryptoFunction, &mh->cryptoThreadArg[x]);
		}
	}

	// wait for all threads to be ready
	for (uint8_t i = 0; i < numThreads; i++) {
		auto kr = semaphore_wait(mh->threadInitReadySignal);
		if (kr != KERN_SUCCESS) {
			MESHLOG("Failed to wait for thread ready signal on iter [%d]. Stop all readers.\n", i);
			return false;
		}
	}

	// Signal all threads to go now.
	auto kr = semaphore_signal_all(mh->threadInitGoSignal);
	if (kr != KERN_SUCCESS) {
		MESHLOG_STR("Failed to signal all threads go signal. Stop all readers.\n");
		return false;
	}

	if (mh->peerConnectionInfo != nullptr) {
		mh->networkRxThreadArg.mh           = mh;
		mh->networkRxThreadArg.whoami_local = 0;

		mh->networkTxThreadArg.mh           = mh;
		mh->networkTxThreadArg.whoami_local = 0;

		atomic_fetch_add(&mh->num_threads, 4);

		pthread_create(&mh->netReceiveThread, nullptr, receiveFromNetworkPeer, &mh->networkRxThreadArg);
		pthread_create(&mh->netSendThread, nullptr, sendToNetworkPeer, &mh->networkTxThreadArg);

		pthread_create(&mh->netSendMultiPartitionThread, nullptr, netSendMultiPartition, &mh->networkTxThreadArg);
		pthread_create(&mh->netReceiveMultiPartitionThread, nullptr, netReceiveMultiPartition, mh);
	}

	return true;
}

static void
StopReaders_Private(MeshHandle_t * mh)
{
	atomic_store(&mh->reader_active, 0);

	for (uint8_t i = 0; i < THREAD_GO_SIGNAL_COUNT; i++) {
		semaphore_signal_all(mh->threadLeaderGoSignal[i]);
	}

	for (uint8_t i = 0; i < kMaxCIOMeshNodes; i++) {
		semaphore_signal(mh->threadSyncGoSignal[i]);
	}

	// Signal the network threads to shutdown.
	semaphore_signal(mh->netSendPeerGoSignal);
	semaphore_signal(mh->netReceivePeerGoSignal);
	semaphore_signal(mh->netReceiveMultiPartitionGoSignal);
	semaphore_signal(mh->netSendMultiPartitionGoSignal);

	// Forward chain automatically stops on the last broadcast and gather
	// This call can do nothing, but that's okay.
	[mh->service stopForwardChain];

	MeshBufferState_t * mbs = (MeshBufferState_t *)atomic_load(&mh->activateChainedBuffers);

	for (uint32_t i = 0; mbs && i < mbs->numBuffers; i++) {
		if ([mh->service interruptWaitingThreads:(mbs->baseBufferId + i)] == NO) {
			MESHLOG("Failed to interrupt waiting threads for bufferId: 0x%llx\n", (mbs->baseBufferId + i));
		}
	}

	// give the threads in the kernel time to notice the change
	usleep(10000);

	for (uint32_t i = 0; mbs && i < mbs->numBuffers; i++) {
		[mh->service clearInterruptState:(mbs->baseBufferId + i)];
	}

	atomic_store(&mh->activateChainedBuffers, NULL);

	return;
}

extern "C" void
MeshDestroyHandle(MeshHandle_t * mh)
{
	StopReaders_Private(mh);

	if (mh->peerConnectionInfo) {
		delete[] mh->peerConnectionInfo;
	}

	delete mh->shadow_arena;
}

extern "C" bool
MeshStopReaders(MeshHandle_t * mh)
{
	StopReaders_Private(mh);

	return true;
}

// MARK: - Handle Management

// TODO: Use destructors for the love of god, either a scopeguard or create a MeshSemaphore class
static void
destroyThreadSyncGoSignal(MeshHandle_t * mh)
{
	for (int i = 0; i < kMaxCIOMeshNodes; i++) {
		semaphore_destroy(mach_task_self(), mh->threadSyncGoSignal[i]);
	}
	semaphore_destroy(mach_task_self(), mh->netReceivePeerGoSignal);
	semaphore_destroy(mach_task_self(), mh->netReceiveMultiPartitionGoSignal);
	semaphore_destroy(mach_task_self(), mh->netSendPeerGoSignal);
	semaphore_destroy(mach_task_self(), mh->netSendMultiPartitionGoSignal);
}

namespace MeshNet   = AppleCIOMeshNet;
namespace MeshUtils = AppleCIOMeshUtils;

static uint64_t
getConnectionNodeMask(MeshHandle_t * mh)
{
	if (mh->partitionIdx == 0) {
		// parition 0
		return 1 << mh->myNodeId | 1 << (mh->myNodeId + 8);
	} else {
		// parition 1
		return 1 << mh->myNodeId | 1 << (mh->myNodeId - 8);
	}
}

static bool
receivedAndDecryptHandshake(MeshHandle_t * mh, MeshCryptoKeyState_t * keyState, AppleCIOMeshNet::TcpConnection & conn)
{
	// Verify the peer is who we think it should be.
	MeshNet::Handshake receivedHandshake;
	auto expectedPeer = mh->peerConnectionInfo->peerInfo.nodeId;
	bool success      = verifyHandshake(mh->stats.logHandle, conn, &receivedHandshake, expectedPeer);
	if (!success) {
		MESHLOG("Failed to verify handshake with peer %u\n", expectedPeer);
		return false;
	}

	MESHLOG("Verified handshake version: %llu, from node %u\n", receivedHandshake.version, receivedHandshake.sender_rank);
	uint8_t decryptedMessage[sizeof(kHandshakeMessage)];

	int error =
	    aes_gcm_decrypt_memory(keyState->crypto_key[expectedPeer], keyState->crypto_key_sz, &keyState->crypto_node_iv[expectedPeer],
	                           receivedHandshake.message, sizeof(kHandshakeMessage), decryptedMessage, receivedHandshake.tag,
	                           sizeof(receivedHandshake.tag), expectedPeer, mh->myNodeId);
	if (error != 0) {
		MESHLOG("Decryption of handshake message failed from node %u\n", expectedPeer);
		return false;
	}
	keyState->crypto_node_iv[expectedPeer].count++;

	if (memcmp(decryptedMessage, kHandshakeMessage, sizeof(kHandshakeMessage)) != 0) {
		MESHLOG("Handshake message body from node %u does not match expected message body.\n", expectedPeer);
		return false;
	}
	return true;
}

static bool
sendEncryptedHandshake(MeshHandle_t * mh, MeshCryptoKeyState_t * keyState, AppleCIOMeshNet::TcpConnection & conn)
{
	AppleCIOMeshNet::Handshake handshake;
	handshake.version        = kHandshakeVersion;
	handshake.message_type   = kHandshakeMessageType;
	handshake.sender_rank    = mh->myNodeId;
	handshake.message_length = sizeof(kHandshakeMessage);
	char tag[kTagSize];

	int error = aes_gcm_encrypt_memory(keyState->crypto_key[mh->myNodeId], keyState->crypto_key_sz,
	                                   &keyState->crypto_node_iv[mh->myNodeId], (void *)kHandshakeMessage,
	                                   sizeof(kHandshakeMessage), handshake.message, tag, kTagSize, mh->myNodeId);
	if (error != 0) {
		MESHLOG("Failed to encrypt handshake message.\n");
		return false;
	}

	memcpy(handshake.tag, tag, kTagSize);
	return sendHandshake(handshake, mh->stats.logHandle, conn);
}

static bool
listenToPeers(MeshHandle_t * mh)
{
	MESHLOG("Listening to peers\n");
	// Get the crypto key to encrypt/decryp the handshake message
	MeshCryptoKeyState_t * keyState = lookupKeyFromMask(mh, getConnectionNodeMask(mh));

	if (keyState == nullptr) {
		MESHLOG("No crypto key set for this node pair.\n");
		return false;
	}

	int32_t rxSocketFd = listenForConnectionNative();
	if (rxSocketFd < 0) {
		return false;
	}
	MeshNet::TcpConnection rxConnection{rxSocketFd};
	MESHLOG("Accepted rx network connection\n");

	// Verify the peer is who we think it should be.
	bool success = receivedAndDecryptHandshake(mh, keyState, rxConnection);
	if (!success) {
		MESHLOG("Failed to receive and decrypt handshake from rx peer\n");
		return false;
	}
	success = sendEncryptedHandshake(mh, keyState, rxConnection);
	if (!success) {
		MESHLOG("Failed to send encrypted handshake to rx peer\n");
		return false;
	}

	// Now repeat the same thing for Tx connection
	int32_t txSocketFd = listenForConnectionNative();
	if (txSocketFd < 0) {
		return false;
	}
	MeshNet::TcpConnection txConnection{txSocketFd};
	MESHLOG("Accepted tx network connection\n");
	success = receivedAndDecryptHandshake(mh, keyState, txConnection);
	if (!success) {
		MESHLOG("Failed to receive and decrypt handshake from tx peer\n");
		return false;
	}

	success = sendEncryptedHandshake(mh, keyState, txConnection);
	if (!success) {
		MESHLOG("Failed to send handshake message to tx peer.\n");
		return false;
	}

	// Success, we have both connections.
	mh->peerConnectionInfo[0].rx_connection = std::move(rxConnection);
	mh->peerConnectionInfo[0].tx_connection = std::move(txConnection);
	return true;
}

static bool
connectToPeers(MeshHandle_t * mh)
{
	MESHLOGx("Connecting to peers\n");
	PeerConnectionInfo * info                         = mh->peerConnectionInfo;
	info[0].peerInfo.hostname[kMaxHostnameLength - 1] = 0; // just in case :)

	MeshCryptoKeyState_t * keyState = lookupKeyFromMask(mh, getConnectionNodeMask(mh));

	if (keyState == nullptr) {
		MESHLOG("No crypto key set for this node pair.\n");
		return false;
	}

	int32_t txSocketfd = connectToPeerNative(info[0].peerInfo.hostname);
	if (txSocketfd < 0) {
		return false;
	}
	MeshNet::TcpConnection txConnection{txSocketfd};

	bool success = sendEncryptedHandshake(mh, keyState, txConnection);
	if (!success) {
		MESHLOG("Failed to send handshake message to tx peer.\n");
		return false;
	}
	success = receivedAndDecryptHandshake(mh, keyState, txConnection);
	if (!success) {
		MESHLOG("Failed to verify handshake with tx peer.\n");
		return false;
	}

	// Now repeat the same thing for rx connection

	int32_t rxSocketfd = connectToPeerNative(info[0].peerInfo.hostname);
	if (rxSocketfd < 0) {
		return false;
	}
	MeshNet::TcpConnection rxConnection{rxSocketfd};

	success = sendEncryptedHandshake(mh, keyState, rxConnection);
	if (!success) {
		MESHLOG("Failed to send handshake message to rx peer.\n");
		return false;
	}
	success = receivedAndDecryptHandshake(mh, keyState, rxConnection);
	if (!success) {
		MESHLOG("Failed to verify handshake with rx peer.\n");
		return false;
	}

	info[0].tx_connection = std::move(txConnection);
	info[0].rx_connection = std::move(rxConnection);
	return true;
}

static int
establishNetworkConnectivity(MeshHandle_t * mh, AppleCIOMeshConfigServiceRef * configService)
{
	// TODO(marco): make this work 32n
	NSArray * peers = [configService getPeerHostnames];
	if (peers == nil) {
		MESHLOG_STR("Found no peers. Array is nil.");
		return -1;
	}
	if (peers.count == 0) {
		MESHLOG_STR("Found no peers. Array is empty. Assuming ensemble does not require network connectivity.");
		// TODO (marco): If we check the ensemble size
		return 0;
	}
	MESHLOG_STR("Establishing network connectivity\n");
	// TODO(32n): create an array of peer connection info

	mh->peerConnectionInfo = new PeerConnectionInfo[3]; // new instead of malloc to default construct members.
	PeerNodeInfo info;
	[peers[0] getValue:&info]; // Extract the struct
	mh->peerConnectionInfo[0].peerInfo = info;

	if (mh->partitionIdx == 0) {
		if (!listenToPeers(mh)) {
			return -2;
		}
	} else {
		if (!connectToPeers(mh)) {
			return -3;
		}
	}
	return (int)peers.count;
}

// myNodeId = extendedNodeId
static MeshHandle_t *
MeshCreate(uint32_t myNodeId, uint32_t nodeCount, uint32_t leaderNodeId, uint8_t partitionIdx)
{
	AppleCIOMeshServiceRef * service             = nil;
	AppleCIOMeshConfigServiceRef * configService = nil;

	// only support 4/8 nodes
	if (nodeCount != 2 && nodeCount != 4 && nodeCount != 8 && nodeCount != 16 && nodeCount != 32) {
		return NULL;
	}

	// create this first so the MESHLOG macro works
	MeshHandle_t * mh = (MeshHandle_t *)calloc(1, sizeof(MeshHandle_t));
	if (mh == NULL) {
		return NULL;
	}
	mh->stats.logHandle = os_log_create("com.apple.CIOMesh", "logging");

	// allocate 10GB of virtual address space.
	// This requires a special entitlement.
	mh->shadow_arena = MeshArena::create(10ull * 1024 * 1024 * 1024);
	if (!mh->shadow_arena) {
		MESHLOG("Failed to create shadow buffer arena.");
		free(mh);
		return nullptr;
	}

	service = getService();
	if (!service) {
		MESHLOG_STR("Was not able to get the AppleCIOMeshService.  Either there is no driver or another process is using it.\n");
		free(mh);
		return NULL;
	}

	configService = getConfigService();
	if (!configService) {
		MESHLOG_STR("No AppleCIOMeshConfigService found. Is the driver installed properly?\n");
		free(mh);
		return NULL;
	}

	uint32_t linksPerChannel;
	if (![configService getHardwareState:&linksPerChannel]) {
		MESHLOG_STR("could not get links per channel.\n");
		free(mh);
		return NULL;
	}

	mh->service           = service;
	mh->chunkDivider      = linksPerChannel;
	mh->extendedNodeCount = nodeCount;
	mh->localNodeCount    = nodeCount > 8 ? 8 : nodeCount;
	atomic_store(&mh->startReadChainedBuffers, NULL);
	atomic_store(&mh->activateChainedBuffers, NULL);

	mh->activePlan.curIdx    = 0;
	mh->activePlan.execCount = 0;
	mh->activePlan.execPlan  = nullptr;

	char * verbosity = getenv("MESH_VERBOSE");
	if (verbosity) {
		mh->verbose_level = (uint32_t)strtoul(verbosity, NULL, 0);
	} else {
		// No env. variable, check if we have cfprefs
		CFNumberRef cf_verbosity = preferenceIntValue(CFSTR("LogVerbosity"), CFSTR("com.apple.cloudos.AppleCIOMesh"));
		if (cf_verbosity == nullptr) {
			mh->verbose_level = LogStats; // will just log stats by default
		} else {
			if (!CFNumberGetValue(cf_verbosity, kCFNumberIntType, &mh->verbose_level)) {
				mh->verbose_level = LogStats; // will just log stats by default
			}
			CFRelease(cf_verbosity);
		}
	}
	MESHLOG_DEFAULT("Verbosity level is set to %d\n", mh->verbose_level);

	// we don't need to worry about releasing this dispatch semaphore later on
	// because it is ARC and autorelease managed
	mh->meshSynchronizeSem = dispatch_semaphore_create(0);
	semaphore_create(mach_task_self(), &mh->threadInitGoSignal, SYNC_POLICY_FIFO, 0);
	semaphore_create(mach_task_self(), &mh->threadInitReadySignal, SYNC_POLICY_FIFO, 0);
	semaphore_create(mach_task_self(), &mh->netReceivePeerGoSignal, SYNC_POLICY_FIFO, 0);
	semaphore_create(mach_task_self(), &mh->netReceiveMultiPartitionGoSignal, SYNC_POLICY_FIFO, 0);
	semaphore_create(mach_task_self(), &mh->netSendPeerGoSignal, SYNC_POLICY_FIFO, 0);
	semaphore_create(mach_task_self(), &mh->netSendMultiPartitionGoSignal, SYNC_POLICY_FIFO, 0);

	semaphore_create(mach_task_self(), &mh->threadSyncWaitSignal, SYNC_POLICY_FIFO, 0);
	for (int i = 0; i < THREAD_GO_SIGNAL_COUNT; i++) {
		semaphore_create(mach_task_self(), &mh->threadLeaderGoSignal[i], SYNC_POLICY_FIFO, 0);
	}

	for (int i = 0; i < kMaxCIOMeshNodes; i++) {
		semaphore_create(mach_task_self(), &mh->threadSyncGoSignal[i], SYNC_POLICY_FIFO, 0);
	}
	mh->syncGoIdx = 0;
	atomic_store(&mh->pendingMBSAssignmentState, NoAssignment);

	mh->stats.syncMinTime                        = 9999999999;
	mh->stats.syncMinIter                        = -1;
	mh->stats.signpostHandle                     = os_log_create("com.apple.CIOMesh", "signpost");
	mh->stats.broadcastAndGatherIntervalSignpost = os_log_create("com.apple.CIOMesh", "BroadcastAndGather");
	mh->stats.incomingDataSignpost               = os_signpost_id_generate(mh->stats.signpostHandle);
	mh->stats.broadcastCompleteSignpost          = os_signpost_id_generate(mh->stats.signpostHandle);
	mh->stats.longSyncSignpost                   = os_signpost_id_generate(mh->stats.signpostHandle);
	mh->stats.zeroSyncSignpost                   = os_signpost_id_generate(mh->stats.signpostHandle);
	mh->stats.cryptoSignpost                     = os_signpost_id_generate(mh->stats.signpostHandle);
	mh->stats.threadAliveSignpost                = os_signpost_id_generate(mh->stats.signpostHandle);

	// this is local to this function only
	auto concurrentQueueAttributes =
	    dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT, QOS_CLASS_USER_INTERACTIVE, +10);

	// we don't need to worry about releasing this dispatch queue later on
	// because it is ARC and autorelease managed
	mh->cioKernelQ = dispatch_queue_create("cioKernelQueue", concurrentQueueAttributes);
	[service setDispatchQueue:mh->cioKernelQ];

	[service onMeshSynchronized:^{ dispatch_semaphore_signal(mh->meshSynchronizeSem); }];

	mh->assignments = (NodeAssignment_t *)malloc(sizeof(NodeAssignment_t) * mh->localNodeCount);
	if (mh->assignments == NULL) {
		semaphore_destroy(mach_task_self(), mh->threadInitGoSignal);
		semaphore_destroy(mach_task_self(), mh->threadInitReadySignal);
		semaphore_destroy(mach_task_self(), mh->threadSyncWaitSignal);
		for (int i = 0; i < THREAD_GO_SIGNAL_COUNT; i++) {
			semaphore_destroy(mach_task_self(), mh->threadLeaderGoSignal[i]);
		}
		destroyThreadSyncGoSignal(mh);
		free(mh);
		return NULL;
	}
	bool foundSelf = false;

	MeshConnectedNodeInfo * connectedNodes = getAssignments(configService);

	// we ignore the connectedNodes->nodeCount because it's always 8
	// even when not all nodes are connected.
	// instead we'll use the value that was passed into MeshCreate()

	auto myLocalNodeId = myNodeId % kMaxCIOMeshNodes;
	mh->myNodeId       = myNodeId;
	mh->partitionIdx   = partitionIdx;
	MESHLOG("my node id is %d, partitionIdx is %d\n", myNodeId, mh->partitionIdx);

	for (uint32_t i = 0; i < mh->localNodeCount; i++) {
		mh->assignments[i].localNodeRank    = i;
		mh->assignments[i].extendedNodeRank = i + (mh->partitionIdx * 8);

		if (i == myLocalNodeId) {
			foundSelf = true;
		}

		MeshNodeInfo * realAssignment = &connectedNodes->nodes[i];

		mh->assignments[i].inputChannel = realAssignment->inputChannel;
		memcpy(&mh->assignments[i].outputChannels[0], &realAssignment->outputChannels[0],
		       sizeof(mh->assignments[i].outputChannels));
		mh->assignments[i].outputChannelCount = realAssignment->outputChannelCount;
		// the rest of the assignment info will get filled in later
	}
	free(connectedNodes);

	if (!foundSelf) {
		MESHLOG_STR("Self responsibility is required.\n");
		semaphore_destroy(mach_task_self(), mh->threadInitGoSignal);
		semaphore_destroy(mach_task_self(), mh->threadInitReadySignal);
		semaphore_destroy(mach_task_self(), mh->threadSyncWaitSignal);
		for (int i = 0; i < THREAD_GO_SIGNAL_COUNT; i++) {
			semaphore_destroy(mach_task_self(), mh->threadLeaderGoSignal[i]);
		}
		destroyThreadSyncGoSignal(mh);
		delete[] mh->peerConnectionInfo;
		free(mh->assignments);
		free(mh);
		return NULL;
	}

	// We need to syncrhonize before trying to get the key so that,
	// if the process restarts while waiting for other nodes to be also
	// up and running, we don't just use up the key
	[mh->service synchronizeMesh];

	while (true) {
#define MESH_SYNCHRONIZE_TIMEOUT 30000000000
		dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, MESH_SYNCHRONIZE_TIMEOUT);
		if (dispatch_semaphore_wait(mh->meshSynchronizeSem, timeout) == 0) {
			break;
		} else {
			MESHLOG_STR("Failed to synchronize mesh.\n");
			semaphore_destroy(mach_task_self(), mh->threadInitGoSignal);
			semaphore_destroy(mach_task_self(), mh->threadInitReadySignal);
			semaphore_destroy(mach_task_self(), mh->threadSyncWaitSignal);
			for (int i = 0; i < THREAD_GO_SIGNAL_COUNT; i++) {
				semaphore_destroy(mach_task_self(), mh->threadLeaderGoSignal[i]);
			}
			destroyThreadSyncGoSignal(mh);
			free(mh->assignments);
			free(mh);
			return NULL;
		}
	}

	uint32_t flags = 0;
	static char retrievedKey[MAX_CRYPTO_KEYSIZE];
	size_t rKeyMaxSize = sizeof(retrievedKey);
	size_t rKeyLen     = 0;

	NSData * retreivedKeyData = [configService getCryptoKeyForSize:rKeyMaxSize andFlags:&flags];

	populateMasks(mh);

	if (retreivedKeyData) {
		rKeyLen = rKeyMaxSize;
		memcpy(&retrievedKey[0], [retreivedKeyData bytes], rKeyLen);
		int ret = -1;
		for (uint64_t i = 0; i < mh->cryptoKeyArray.key_count; i++) {
			ret = setNodeKeys(mh, i, (const void *)retrievedKey, rKeyLen);
			if (ret != 0) {
				MESHLOG_STR("Failed to generate per node keys\n");
				semaphore_destroy(mach_task_self(), mh->threadInitGoSignal);
				semaphore_destroy(mach_task_self(), mh->threadInitReadySignal);
				semaphore_destroy(mach_task_self(), mh->threadSyncWaitSignal);
				for (int i = 0; i < THREAD_GO_SIGNAL_COUNT; i++) {
					semaphore_destroy(mach_task_self(), mh->threadLeaderGoSignal[i]);
				}
				destroyThreadSyncGoSignal(mh);
				free(mh->assignments);
				free(mh);
				return NULL;
			} else {
				mh->cryptoKeyArray.keys[i].crypto_key_sz = rKeyLen;
			}
		}
		memset_s(retrievedKey, sizeof(retrievedKey), 0, sizeof(retrievedKey));
		MESHLOG("Crypto enabled: retrieved key size %zd flags: 0x%x\n", [retreivedKeyData length], flags);
	} else {
		MESHLOG_STR("Failed to get the crypto key or crypto not enabled.\n");
		semaphore_destroy(mach_task_self(), mh->threadInitGoSignal);
		semaphore_destroy(mach_task_self(), mh->threadInitReadySignal);
		semaphore_destroy(mach_task_self(), mh->threadSyncWaitSignal);
		for (int i = 0; i < THREAD_GO_SIGNAL_COUNT; i++) {
			semaphore_destroy(mach_task_self(), mh->threadLeaderGoSignal[i]);
		}
		destroyThreadSyncGoSignal(mh);
		free(mh->assignments);
		free(mh);
		return NULL;
	}

	mh->leaderNodeId = leaderNodeId;
	// establishNetworkConnectivity returns the number of peers. If the number of peers is 0
	// That means this might be <16n ensemble.
	// If it returns a negative value, then we are not able to retrieve information about
	// the number of peers, so we should fail the MeshCreate function.
	//
	// Instead of having multiple return values to mean different things, it's better
	// if the ensemble-confguration process sets the ensemble size before hand, so we
	// are explicit about our expectations and fail fast.

	// TODO (marco): Check the ensemble size before calling this function.
	if (establishNetworkConnectivity(mh, configService) < 0) {
		mh->peerConnectionInfo = nullptr;
		MESHLOG_STR("Failed to establish network connectivity.\n");
		semaphore_destroy(mach_task_self(), mh->threadInitGoSignal);
		semaphore_destroy(mach_task_self(), mh->threadInitReadySignal);
		semaphore_destroy(mach_task_self(), mh->threadSyncWaitSignal);
		for (int i = 0; i < THREAD_GO_SIGNAL_COUNT; i++) {
			semaphore_destroy(mach_task_self(), mh->threadLeaderGoSignal[i]);
		}
		destroyThreadSyncGoSignal(mh);
		delete[] mh->peerConnectionInfo;
		free(mh->assignments);
		free(mh);
		return NULL;
	}

	MESHLOG("My NodeId is %d and the leader is %d\n", mh->myNodeId, mh->leaderNodeId);

	// Start the readers after we are ready to send the mesh handle back
	if (!StartReaders_Private(mh)) {
		semaphore_destroy(mach_task_self(), mh->threadInitGoSignal);
		semaphore_destroy(mach_task_self(), mh->threadInitReadySignal);
		semaphore_destroy(mach_task_self(), mh->threadSyncWaitSignal);
		for (int i = 0; i < THREAD_GO_SIGNAL_COUNT; i++) {
			semaphore_destroy(mach_task_self(), mh->threadLeaderGoSignal[i]);
		}

		for (int i = 0; i < kMaxCIOMeshNodes; i++) {
			semaphore_destroy(mach_task_self(), mh->threadSyncGoSignal[i]);
		}
		free(mh->assignments);
		free(mh);
		return NULL;
	}

	return mh;
}

extern "C" MeshHandle_t *
MeshCreateHandle(uint32_t leaderNodeId)
{
	uint32_t myNodeId, numNodes;
	if (!MeshGetInfo(&myNodeId, &numNodes)) {
		return NULL;
	}

	// spin for 50ms
	uint64_t start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
	while ((clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) < (50 * 1000 * 1000)) {}

	return MeshCreate(myNodeId, numNodes, leaderNodeId, myNodeId / 8);
}

extern "C" void
MeshSetMaxTimeout(MeshHandle_t * mh, uint64_t maxWaitNanos)
{
	[mh->service setMaxWaitTime:maxWaitNanos];
}

extern "C" int
MeshClaim(__unused MeshHandle_t * mh)
{
	return 0;
}

extern "C" void
MeshReleaseClaim(__unused MeshHandle_t * mh)
{
}

// MARK: - Broadcast and Gather

// Calculates the ideal chunk size for a block size.
static size_t
calculateChunkSize(MeshHandle_t * mh, uint64_t blockSize)
{
	// Note: The maximum number of chunks per block is 4, this needs to match
	// MAX_CHUNKS_PER_BLOCK.
	// Note 2: the values in this if/else block were determined through experiments
	// looking at performance with llmsim; for smaller block sizes there is too
	// much overhead per-chunk to make it worth splitting things up; only above
	// 256k is it worth having up to 4 chunks.
	size_t chunkSize;
	if (blockSize <= 128 * 1024) {
		chunkSize = blockSize;
	} else if (blockSize <= 256 * 1024) {
		chunkSize = blockSize / 2;
	} else {
		uint8_t divisor = 4;
		chunkSize       = blockSize / divisor;

		// Note: Chunksize has to be limited to 16MB max, this will further
		// get split into 2 so each link will send a 8MB chunk. This way
		// we will never enqueue too much into the NHI rings and the driver
		// will enqueue an additional chunk when the first chunk has finished.
		// Let's keep dividing until we get down to 16MB.
		while (chunkSize > kMaxChunkSize) {
			divisor *= 2;
			chunkSize = blockSize / divisor;

			if (divisor == 128) {
				MESHLOG("Blocksize %lld is too big for CIOMesh. Maybe you want a floppy disk?\n", blockSize);
				return 0;
			}
		}
	}

	return chunkSize;
}

extern "C" int
MeshSetupBuffersEx_Private(MeshHandle_t * mh, MeshBufferSet_t * bufferSets, uint16_t count)
{
	mh->stats.outgoingSize = 0;
	mh->stats.incomingSize = 0;

	for (int i = 0; i < count; i++) {
		auto ret = MeshSetupBuffers_Private(mh, bufferSets[i].bufferId, bufferSets[i].bufferSize, bufferSets[i].sectionSize,
		                                    bufferSets[i].blockSize, bufferSets[i].chunkSize, bufferSets[i].bufferPtrs,
		                                    bufferSets[i].numBuffers, bufferSets[i].nodeMask, &bufferSets[i].mbs);
		if (ret != 0) {
			return ret;
		}
	}

	return 0;
}

extern "C" int
MeshSetupBuffers_Private(MeshHandle_t * mh,
                         uint64_t bufferId,
                         uint64_t bufferSize,
                         uint64_t sectionSize,
                         uint64_t blockSize,
                         uint64_t chunkSize,
                         void ** bufferPtrs,
                         uint32_t numBuffers,
                         uint64_t nodeMask,
                         MeshBufferState_t ** ret_mbs)
{
	if (blockSize == 0 || bufferSize == 0 || chunkSize == 0) {
		MESHLOG("Invalid blockSize: %llu, bufferSize: %llu, chunkSize: %llu\n", blockSize, bufferSize, chunkSize);
		return EINVAL;
	}

	if (!isNodeParticipating(mh->myNodeId, nodeMask)) {
		MESHLOG("Node %u is NOT participating in nodeMask %llu", mh->myNodeId, nodeMask);
		return EINVAL;
	}

	if (!isValidNodeMask(nodeMask)) {
		MESHLOG("Invalid node mask was passsed in: %llu", nodeMask);
		return EINVAL;
	}

	const bool p2pMask = isP2PMask(nodeMask, mh->partitionIdx);
	if (!p2pMask && numBuffers < 2) {
		// masks that involve CIO must contain more than 1 buffer, because the driver cannot
		// send and prepare the same buffer simultaneously.
		MESHLOG("numBuffers must be greater than 1 for masks involving CIO\n");
		return EINVAL;
	}

	int retVal             = 0;
	uint64_t userChunkSize = 0;
	uint64_t breakSize     = 0, breakChunk;
	uint64_t breakChunk_i, maxBreaks;

	double expected_sync_time_us;
	int64_t startForwardOffset           = -1;
	int64_t endForwardOffset             = -1;
	uint64_t allocatedChunkSize          = 0;
	const uint8_t cioNodeCount           = getLocalNodeCountFromMask(nodeMask, mh->partitionIdx);
	const uint8_t participatingNodeCount = getNodeCountFromMask(nodeMask);
	const uint8_t localMask              = calculateLocalNodeMask(nodeMask, mh, false /* excludeSelf */);
	bool forwardChainEnabled             = (numBuffers > 1) && cioNodeCount == 8;

	uint64_t chunksPerBlock     = blockSize / chunkSize;
	uint8_t partitionCount      = getPartitionCountFromMask(nodeMask);
	uint8_t currentPartitionIdx = 0;

	MeshBufferState_t * mbs = NULL;

	// initial sanity checks
	if (bufferSize % participatingNodeCount != 0) {
		MESHLOG("Buffer Size %lld does not divide into nodes %d\n", bufferSize, participatingNodeCount);
		retVal = EINVAL;
		goto fail;
	}

	mbs = (MeshBufferState_t *)calloc(1, sizeof(MeshBufferState_t));

	*ret_mbs = NULL;
	if (mbs == NULL) {
		retVal = EINVAL;
		goto fail;
	}

	mbs->test_CopyTagsForNetRx = false;
	mbs->baseBufferId          = bufferId;
	mbs->userBufferSize        = bufferSize;
	mbs->userBlockSize         = blockSize;
	mbs->userChunkSize         = chunkSize;
	mbs->userSectionSize       = sectionSize;
	mbs->numBuffers            = numBuffers;
	mbs->curIteration          = 0;
	mbs->forwardChainId        = -1;
	atomic_store(&mbs->firstPrepareDone, false);
	atomic_store(&mbs->activeReadRemaining, 0);
	atomic_store(&mbs->broadcastActive, false);

	userChunkSize = chunkSize / mh->chunkDivider;

	// Make the actual chunksize a multiple of 4K to avoid NHI double buffering.
	allocatedChunkSize = (userChunkSize + 4095) & ((uint64_t)~4095);
	mbs->chunkSize     = allocatedChunkSize * mh->chunkDivider;
	mbs->blockSize     = mbs->chunkSize * chunksPerBlock;
	if (participatingNodeCount > kMaxCIOMeshNodes) {
		mbs->sectionSize = mbs->blockSize * kMaxCIOMeshNodes;
	} else {
		mbs->sectionSize = mbs->blockSize * (uint64_t)participatingNodeCount;
	}
	mbs->bufferSize = mbs->sectionSize * partitionCount;
	mbs->nodeMask   = nodeMask;
	mbs->maxReads   = 0;
	mbs->plan       = nullptr;

	mbs->assignedCryptoState = lookupKeyFromMask(mh, mbs->nodeMask);
	CHECK(mbs->assignedCryptoState != nullptr, "Invalid nodemask: %llx\n", mbs->nodeMask);

	if (userChunkSize <= 32768) {
		maxBreaks = 2;
	} else if ((userChunkSize / 4) <= 262144) {
		maxBreaks = 4;
	} else {
		maxBreaks = 8;
	}

	//
	// make sure that maxBreaks is never greater than kMaxTBTCommandCount
	// because the MUCI::SharedMemory data structure can not have more
	// entries than that in the forwardBreakdown array (as well as the
	// kext having dependencies on this too)
	//
	if (maxBreaks > kMaxTBTCommandCount) {
		maxBreaks = kMaxTBTCommandCount;
	}

	// make sure each chunk is a multiple of 4k
	breakChunk = ((userChunkSize / maxBreaks) + 4095) & (uint64_t)~4095;
	for (breakChunk_i = 0; breakChunk_i < maxBreaks - 1; breakChunk_i++) {
		mbs->forwardBreakdown[breakChunk_i] = (int64_t)breakChunk;
		breakSize += breakChunk;
	}
	if (breakSize > userChunkSize) {
		// We overshot when we made each forward breakdown a multiple of 4K
		mbs->forwardBreakdown[breakChunk_i - 1] -= (breakSize - userChunkSize);
	} else {
		// any remainder goes in the last breakdown -- this will either be 0 or 4K
		mbs->forwardBreakdown[breakChunk_i] = (int64_t)(userChunkSize - breakSize);
	}

	// connect the apps buffers to the mesh driver
	mbs->bufferInfo = (CIOBufferInfo_t *)calloc(mbs->numBuffers, sizeof(CIOBufferInfo_t));
	if (mbs->bufferInfo == NULL) {
		MESHLOG("Could not allocate %d nodes of BufferInfo_t's\n", mbs->numBuffers);
		retVal = ENOMEM;
		goto fail;
	}

	if (connectBuffersToMesh(mh, mbs, bufferPtrs) != 0) {
		MESHLOG_STR("Failed to allocate all buffers.\n");
		retVal = ENOMEM;
		goto fail;
	}

	mh->stats.outgoingSize += (((double)mbs->blockSize) * (participatingNodeCount - 1) * 8) / kBytesPerGiga;

	currentPartitionIdx = mh->partitionIdx;
	// TODO(marco): this doesn't handle partitionIdx gaps (skips) when the partitions involved are 0 and 3 for example.
	// Should do a helper function that incoporates the mask to determine the next partitionIdx
	for (uint8_t pCount = 0; pCount < partitionCount; pCount++, currentPartitionIdx = (currentPartitionIdx + 1) % partitionCount) {
		// assign all buffers now.
		for (uint32_t i = 0; i < mh->localNodeCount; i++) {
			// Skip setting up any shared memory if we are not participating in this buffer to begin with.
			if (!isNodeParticipating(mh->assignments[i].localNodeRank, localMask)) {
				MESHLOG("Node rank %d(%d) is not participating in local mask (%x), skipping buffer assignment\n",
				        mh->assignments[i].localNodeRank, mh->assignments[i].extendedNodeRank, localMask);
				continue;
			}

			NodeAssignment_t assignment;

			assignment               = mh->assignments[i];
			const auto blockOffset   = getBufferOffsetForNode(localMask, assignment.localNodeRank);
			const auto sectionOffset = getSectionOffsetForPartition(nodeMask, currentPartitionIdx);

			// Have to setup inputs before outputs
			if (assignment.inputChannel != -1) {
				for (uint32_t j = 0; j < mbs->numBuffers; j++) {
					for (uint64_t k = 0; k < mbs->blockSize; k += mbs->chunkSize) {
						uint64_t offset = sectionOffset * mbs->sectionSize;
						offset += blockOffset * mbs->blockSize + k;
						auto test = [mh->service assignSharedMemory:(mbs->baseBufferId + j)
						                                   atOffset:offset
						                                     ofSize:mbs->chunkSize
						                      toIncomingMeshChannel:(uint64_t)assignment.inputChannel
						                             withAccessMode:0x2
						                                   fromNode:assignment.localNodeRank];
						if (!test) {
							MESHLOGx("Failed to assign input for bufferId: 0x%llx, offset: %lld for node: %d\n",
							         (mbs->baseBufferId + j), offset, assignment.localNodeRank);
						}
					}
				}
			}

			if (assignment.outputChannelCount > 0) {
				uint64_t outputMask = calculateLocalNodeMask(nodeMask, mh, true /* excludeSelf */);
				if (assignment.inputChannel != -1) {
					// In the assignment in which the current node will be forwarding data, remove the sender from the
					// output mask. i.e. don't output to the node that gave me the input.
					uint64_t target = 0x1u << assignment.localNodeRank;
					outputMask      = ~target & outputMask;
				}

				for (uint32_t j = 0; j < mbs->numBuffers; j++) {
					if ((mbs->blockSize % mbs->bufferInfo[j].chunkSize) != 0) {
						MESHLOG("Size for node is %lldk but that is not an even multiple of the chunk size %lld\n",
						        (uint64_t)mbs->blockSize / 1024, mbs->bufferInfo[j].chunkSize);
						exit(1);
					}

					for (uint64_t k = 0; k < mbs->blockSize; k += mbs->chunkSize) {
						uint64_t offset = sectionOffset * mbs->sectionSize;
						offset += blockOffset * mbs->blockSize + k;
						[mh->service assignSharedMemory:(mbs->baseBufferId + j)
						                       atOffset:offset
						                         ofSize:mbs->chunkSize
						         toOutgoingMeshChannels:outputMask
						                 withAccessMode:0x2
						                       fromNode:assignment.localNodeRank];
					}
				}

				// found our forward
				if (assignment.inputChannel != -1) {
					uint64_t offset = sectionOffset * mbs->sectionSize;
					offset += blockOffset * mbs->blockSize;
					if (startForwardOffset == -1) {
						startForwardOffset = (int64_t)offset;
						endForwardOffset   = (int64_t)((uint64_t)startForwardOffset + mbs->blockSize - mbs->chunkSize);
					}
				}
			}
		}
	}

	// The forwarder is automatically started. In the default mode it is waiting
	// for a Forwarding RX to complete and the forwarder will prepare+forward it.
	// A forward can be created here, and held until it is ready to start the
	// forward chain, where the forwarder will preare all the buffers much faster.

	if (forwardChainEnabled && startForwardOffset != -1) {
		uint8_t tmp = 0xFF;

		[mh->service setupForwardChainWithId:(uint8_t *)&tmp
		                                from:mbs->baseBufferId + 0
		                                  to:mbs->baseBufferId + mbs->numBuffers - 1
		                         startOffset:(uint64_t)startForwardOffset
		                           endOffset:(uint64_t)endForwardOffset
		                   withSectionOffset:mbs->sectionSize
		                        sectionCount:partitionCount];
		mbs->forwardChainId = tmp;
	}

	mh->stats.incomingSize += (((double)mbs->bufferSize / participatingNodeCount) * participatingNodeCount * 8) / kBytesPerGiga;
	mbs->curBufferIdx = 0;

	// last thing: setup the bins for the histogram.  We calculate the expected min sync
	// time, add 10 usec and then create bins that grow logarthimically.

	expected_sync_time_us = ceil((((chunkSize * 8) / (double)CIO40_ACTUAL_LINE_RATE) * kUsPerSecond)) + 10;
	for (int i = 0; i < MESH_SYNC_HISTOGRAM_COUNT; i++) {
		mh->stats.syncTimeHistogramBins[i]  = (uint64_t)expected_sync_time_us;
		mbs->stats.syncTimeHistogramBins[i] = (uint64_t)expected_sync_time_us;
		expected_sync_time_us *= 2;
	}

	*ret_mbs = mbs;

	return 0;

fail:
	if (mbs && mbs->bufferInfo) {
		free(mbs->bufferInfo);
	}

	if (mbs) {
		free(mbs);
	}

	return retVal;
}

static uint64_t
createAllEnsembleMask(MeshHandle_t * mh)
{
	/* Create the node mask by setting the lower n bits to 1, if n is larger than 64 then all bits are set to 1 */
	auto n = mh->extendedNodeCount;
	if (n >= std::numeric_limits<uint64_t>::digits)
		return ~uint64_t(0);
	return (uint64_t(1) << n) - 1;
}

extern "C" int
MeshSetupBuffers(MeshHandle_t * mh,
                 uint64_t bufferId,
                 uint64_t bufferSize,
                 uint64_t blockSize,
                 uint64_t /* ignored */,
                 void ** bufferPtrs,
                 uint32_t numBuffers,
                 MeshBufferState_t ** ret_mbs)
{
	if (blockSize % kMeshBufferBlockSizeMultiple != 0) {
		MESHLOG("application bug: MeshSetupBuffers called with blockSize: %lld which is not a multiple of %d.", blockSize,
		        kMeshBufferBlockSizeMultiple);
	}

	uint64_t chunkSize = calculateChunkSize(mh, blockSize);

	auto nodeMask          = createAllEnsembleMask(mh);
	const auto sectionSize = bufferSize; // Legacy API, used with small ensembles (8 or less). No sections needed.
	return MeshSetupBuffers_Private(mh, bufferId, bufferSize, sectionSize, blockSize, chunkSize, bufferPtrs, numBuffers, nodeMask,
	                                ret_mbs);
}

extern "C" int
MeshSetupBufferEx(MeshHandle_t * mh, MeshBufferSet_t * bufferSets, uint16_t count)
{
	for (int i = 0; i < count; i++) {
		const auto participatingNodeCount = getNodeCountFromMask(bufferSets[i].nodeMask);
		const uint64_t partitionCount     = getPartitionCountFromMask(bufferSets[i].nodeMask);
		uint64_t sectionSize              = bufferSets[i].bufferSize / partitionCount;
		uint64_t blockSize                = 0;
		if (participatingNodeCount > kMaxCIOMeshNodes) { // we are doing a 16+ BaG, so split the buffer into sections.
			blockSize = sectionSize / kMaxCIOMeshNodes;
		} else {
			blockSize = sectionSize / participatingNodeCount;
		}

		bufferSets[i].blockSize   = blockSize;
		bufferSets[i].sectionSize = sectionSize;
		bufferSets[i].chunkSize   = calculateChunkSize(mh, blockSize);
	}

	return MeshSetupBuffersEx_Private(mh, bufferSets, count);
}

#define MAX_CTR 100

extern "C" int
MeshReleaseBuffers(MeshHandle_t * mh, MeshBufferState_t * mbs)
{
	uint32_t ctr = 0;

	// check if this mbs is in the active plan
	bool isWorkedOn = false;
	if ((MeshBufferState_t *)atomic_load(&mh->activateChainedBuffers) == mbs || mh->pendingMBSAssignBuffer == mbs) {
		isWorkedOn = true;
	}

	for (int i = 0; i < mh->activePlan.execCount && !isWorkedOn; i++) {
		if (mh->activePlan.execPlan[i].mbs == mbs) {
			isWorkedOn = true;
		}
	}

	if (isWorkedOn) {
		while (atomic_load(&mh->reader_blocked) != atomic_load(&mh->num_threads) && ctr++ < MAX_CTR) {
			usleep(100);
		}

		CHECK(ctr < MAX_CTR,
		      "application bug: MeshReleaseBuffers called while only %d/%d readers are blocked (baseBufferId 0x%llx and %d "
		      "buffers ctr %d).\n",
		      atomic_load(&mh->reader_blocked), atomic_load(&mh->num_threads), mbs->baseBufferId, (int)mbs->numBuffers, ctr);
	}

	// free'ing things in reverse order is a little bit better for the driver
	for (int32_t i = (int32_t)mbs->numBuffers - 1; i >= 0; i--) {
		if ([mh->service deallocateSharedMemory:(mbs->baseBufferId + (uint32_t)i) ofSize:mbs->bufferSize] == NO) {
			MESHLOG("Failed to deallocate shared memory bufId 0x%llx size %lld\n", mbs->baseBufferId + (uint32_t)i,
			        mbs->bufferSize);
		}

		if (mbs->bufferInfo[i].shadow != mbs->bufferInfo[i].bufferPtr) {
			mh->shadow_arena->dealloc(mbs->bufferSize);
		}
	}

	double averageSyncTimeUsec = ((double)mbs->stats.syncTotalTime / (double)mbs->stats.syncCounter) / 1000.0;
	MESHLOG("mbs performance: averageSyncTime: %8.2f\n", averageSyncTimeUsec);
	uint64_t base = 0;
	for (int i = 0; i < MESH_SYNC_HISTOGRAM_COUNT; i++) {
		if (mbs->stats.syncTimeHistogram[i] != 0) {
			if (i < MESH_SYNC_HISTOGRAM_COUNT - 1) {
				MESHLOG("	%6lld - %6lld usec: %lld\n", base, mbs->stats.syncTimeHistogramBins[i],
				        mbs->stats.syncTimeHistogram[i]);
			} else {
				MESHLOG("		   > %6lld usec: %lld\n", base, mbs->stats.syncTimeHistogram[i]);
			}
		}
		base = mbs->stats.syncTimeHistogramBins[i] + 1;
	}
	MESHLOG_STR("mbs performance large times: \n");
	MESHLOG_STR("   ");
	double largeUsec    = 0.0;
	double largeCounter = 0;
	for (int i = 0; i < LARGE_MAX_COUNTER; i++) {
		if (mbs->stats.largeTimes[i] == 0) {
			break;
		}
		MESHLOG("long sync time: %lldns [iter:%lld],", mbs->stats.largeTimes[i], mbs->stats.largeTimesIter[i]);
		largeUsec += mbs->stats.largeTimes[i];
		largeCounter++;
	}

	double averageCorrectedTimeUsec =
	    (((double)mbs->stats.syncTotalTime - largeUsec) / ((double)mbs->stats.syncCounter - largeCounter)) / 1000.0;
	MESHLOG("mbs performance: averageSyncTime (minus large): %8.2f\n", averageCorrectedTimeUsec);

	MESHLOG_STR("\n");

	mbs->baseBufferId = 0;
	mbs->numBuffers   = 0;
	mbs->bufferSize   = 0;
	free(mbs->bufferInfo);
	mbs->bufferInfo = NULL;

	free(mbs);

	return 0;
}

extern "C" int
MeshClearBuffers(MeshHandle_t * mh, MeshBufferState_t * mbs)
{
	uint64_t ctr = 0;
	while (atomic_load(&mh->pendingMBSAssignmentState) != NoAssignment && ctr++ < MAX_SPIN) {
		// burn, baby burn
	}

	if (ctr >= MAX_SPIN) {
		MESHLOG_STR("MeshBuffer not prepared in time when clearing buffers.\n");
		return ETIMEDOUT;
	}

	if ((MeshBufferState_t *)atomic_load(&mh->activateChainedBuffers) == mbs) {
		MESHLOG_STR("Trying to clear assigned buffer. This is not supported.\n");
		return EINVAL;
	}

	for (uint32_t i = 0; i < mbs->numBuffers; i++) {
		memset_s(mbs->bufferInfo[i].shadow, mbs->bufferSize, 0, mbs->bufferSize);
	}

	if (![mh->service resetBuffer:mbs->baseBufferId]) {
		MESHLOG("Failed to reset bufferId 0x%llx", mbs->baseBufferId);
		return EINVAL;
	}

	mbs->curBufferIdx = 0;
	atomic_store(&mbs->currentReadIdx, 0);

	return 0;
}

extern "C" int
MeshBroadcastAndGather(MeshHandle_t * mh, MeshBufferState_t * mbs)
{
	if (!mbs->sync0Complete) {
		os_signpost_event_emit(mh->stats.signpostHandle, mh->stats.zeroSyncSignpost, "0Sync",
		                       "mesh buffer state baseBufferId 0x%llx", mbs->baseBufferId);
		mbs->sync0Complete = true;
	}

	if (!isNodeParticipating(mh->myNodeId, mbs->nodeMask)) {
		MESHLOG("I am not participating in bufferId:0x%llx, not BAGing\n", mbs->baseBufferId);
		return 0;
	}

	uint64_t ctr = 0;

	// Wait until the pending assignment has been assigned
	while (atomic_load(&mh->pendingMBSAssignmentState) != NoAssignment && ctr++ < MAX_SPIN) {
		// burn, baby burn
	}

	if (ctr >= MAX_SPIN) {
		MESHLOG_STR("MeshBuffer not prepared in time.\n");
		return ETIMEDOUT;
	}

	// Check if the buffer we are BAGing on is the buffer we assigned
	if ((MeshBufferState_t *)atomic_load(&mh->activateChainedBuffers) != mbs) {
		MESHLOG("MeshBufferState not assigned to readers properly active buffer is 0x%llx but we were passed 0x%llx.\n",
		        (uint64_t)atomic_load(&mh->activateChainedBuffers), (uint64_t)mbs);
		return EINVAL;
	}

	// Making sure there isn't a current active BAG when starting this BAG
	bool expectedBroadcastActive = false;
	if (!atomic_compare_exchange_strong(&mbs->broadcastActive, &expectedBroadcastActive, true)) {
		MESHLOG("MeshBufferState already doing broadcastAndGather for bufferId 0x%llx bufferIdx:%u.\n", mbs->baseBufferId,
		        mbs->curBufferIdx);
		return EBUSY;
	}

	if (mh->verbose_level >= LogSignposts) {
		os_signpost_interval_begin(mh->stats.broadcastAndGatherIntervalSignpost, OS_SIGNPOST_ID_EXCLUSIVE, "CIOMesh",
		                           "BaG iteration %lld, mask %llx, blockSize %llu", mbs->curIteration, mbs->nodeMask,
		                           mbs->blockSize);
	}

	const auto partitionCount       = getPartitionCountFromMask(mbs->nodeMask);
	int ret                         = 0;
	uint32_t bufferIdx              = 0;
	const uint64_t sendCount        = mbs->blockSize / mbs->chunkSize;
	const bool p2pMask              = isP2PMask(mbs->nodeMask, mh->partitionIdx);
	const uint64_t networkSendCount = p2pMask ? sendCount : sendCount * (partitionCount - 1);
	const uint8_t cioNodeCount      = getLocalNodeCountFromMask(mbs->nodeMask, mh->partitionIdx);
	uint8_t myLocalNodeId           = mh->myNodeId % kMaxCIOMeshNodes;

	atomic_int encryptReady[sendCount];
	char myTags[sendCount * mh->chunkDivider][kTagSize];

	for (uint8_t pIdx = mh->partitionIdx, sectionsCtr = 0; sectionsCtr < partitionCount;
	     pIdx = (pIdx + 1) % partitionCount, sectionsCtr++) {
		bufferIdx = mbs->curBufferIdx;

		const uint8_t localMask = calculateLocalNodeMask(mbs->nodeMask, mh, false /* excludeSelf */);

		// As NodeN (within a partition), I am responsible for CIO Broadcasting
		// all blockN for the sections. Ie: if I am node 4 within my partition,
		// I have to CIO broadcast all block4 within all sections of the buffer.
		const auto blockOffset   = getBufferOffsetForNode(localMask, myLocalNodeId);
		const auto sectionOffset = getSectionOffsetForPartition(mbs->nodeMask, pIdx);
		uint64_t outgoingOffset  = (sectionOffset * mbs->sectionSize) + (blockOffset * mbs->blockSize);

		/* We only need to encrypt stuff if pIdx = mh->partitionIdx
		 * if we are broadcasting blocks that we received from another partition over the network.
		 * then we should skip to sending over CIO directly. The blocks received are already encrypted.
		 */

		if (pIdx == mh->partitionIdx) {
			mbs->bufferInfo[bufferIdx].blockSent = 0;

			mbs->bufferInfo[bufferIdx].performance.sendStartTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
			mbs->bufferInfo[bufferIdx].performance.sendEndTime   = 0;

			mbs->bufferInfo[bufferIdx].performance.iterId = mbs->curIteration;

			// initialize all the "ready" booleans to chunkDivider if crypto is not
			// available, 0 if crypto is available.
			for (size_t i = 0; i < sizeof(encryptReady) / sizeof(encryptReady[0]); i++) {
				atomic_store(&encryptReady[i], 0);
			}

			// Set the number of network broadcasts to 0, it shouldn't
			// have started broadcasting. We will set it to
			// sendCount * partitionCount-1 (all network broadcast is done)
			// if the nodeMask doesn't have any networking.
			if (partitionCount == 1 && !p2pMask) {
				atomic_store(&mbs->net_broadcast_chunk_count, networkSendCount);
			} else {
				atomic_store(&mbs->net_broadcast_chunk_count, 0);
			}

			if (mbs->test_CopyTagsForNetRx) {
				atomic_store(&mbs->net_broadcast_chunk_count, networkSendCount);
			}

			mh->crypto.assigned_chunk_encrypted = &encryptReady[0];
			atomic_store(&mh->crypto.assigned_encrypt_tag_ptr, (uintptr_t)&myTags[0][0]);

			atomic_store(&mh->crypto.assigned_bufferIdx[mh->myNodeId % 8], bufferIdx);
			atomic_store(&mh->crypto.assigned_mbs[mh->myNodeId % 8], (uintptr_t)mbs);

			// Wait until the encrypt thread has finished preparing to transmit
			// buffers over CIO
			uint64_t start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
			while (!p2pMask && atomic_load(&mbs->firstPrepareDone) == false) {
				sched_yield();
				constexpr uint64_t maxWait_ns = 10 * 1000 * 1000; // 10ms
				uint64_t delta                = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start;
				CHECK(delta <= maxWait_ns, "section %d was not ready in time.\n", pIdx);
			}

			if (mbs->syncRemaining < 1) {
				MESHLOG("Danger!  mh->curCount == %lld\n", mbs->syncRemaining);
				atomic_store(&mbs->broadcastActive, false);
				return ENOBUFS;
			}
		} else {
			// Wait for the section to be ready before doing a broadcast and
			// gather via CIO.

			while (atomic_load(&mbs->bufferInfo[bufferIdx].sectionsReady) < sectionsCtr) {
				sched_yield();
			}
		}

		// Now go through all the cryptoready ints, and as each one is ready, send
		// and prepare
		uint64_t ongoingOffset = outgoingOffset;

		for (uint64_t i = 0; i < sendCount; i++) {
			uint64_t nextChunkOffset = ongoingOffset + mbs->chunkSize;
			uint32_t nextBufferIdx   = bufferIdx;
			// Switch to the next buffer after we are done BaG to all partitions.
			const bool moveToNextBuffer = sectionsCtr == (partitionCount - 1);

			if (moveToNextBuffer && (nextChunkOffset - outgoingOffset) >= mbs->blockSize) {
				nextChunkOffset = 0;
				nextBufferIdx   = (bufferIdx + 1) % mbs->numBuffers;
			}

			// Burn for crypto to be ready (only if we are broadcasting our own block)
			if (pIdx == mh->partitionIdx) {
				while (atomic_load(&encryptReady[i]) != mh->chunkDivider && atomic_load(&mh->reader_active) > 0) {}

				// Crypto is ready, let's also quickly notify the networking TX thread
				// it is safe to send out this chunk.
				atomic_store(&mh->crypto.net_tx_tag_ptr[i], (uintptr_t)&myTags[i * mh->chunkDivider][0]);
				// printf("copying tag:%llx-%llx.\n", ((uint64_t*)tagPtr)[0], ((uint64_t*)tagPtr)[1]);

				// If we are in the test mode, now that we have the encrypted tag
				// we have to copy the tag into the Section RX Tag for all the
				// other sections, and copy the encrypted data.
				if (mbs->test_CopyTagsForNetRx) {
					MeshCopyMyChunkToAllSections_private(mh, mbs, (uint8_t)i, myTags[i * mh->chunkDivider]);
					// Also we have to copy the data into the shadow!
				}
			}

			if (mh->verbose_level >= LogDebug) {
				MESHLOG("sender: broadcasting bufferId 0x%llx at offset %lld for %lld nextBufId: 0x%llx nextOffset %lld\n",
				        mbs->baseBufferId + bufferIdx, ongoingOffset, mbs->chunkSize, mbs->baseBufferId + nextBufferIdx,
				        outgoingOffset + nextChunkOffset);
			}

			if (cioNodeCount > 1) {
				char * gcmTag;

				// The tag is something we produced if we are BaG-ing our own block.
				// But if we are BaG-ing a block received from another partition, then we should use the tags
				// received from that partition over the network.
				if (pIdx == mh->partitionIdx) {
					gcmTag = &myTags[i * mh->chunkDivider][0];
					// printf("Sending the following gcm tag on CIO 0x%llx-%llx\n", ((uint64_t *)gcmTag)[0], ((uint64_t
					// *)gcmTag)[1]);
				} else {
					// should not be null since the |sectionsReady| variable above has been incremented.
					gcmTag = (char *)mbs->bufferInfo[bufferIdx].netSectionRxTag[sectionsCtr][i * mh->chunkDivider];
					// printf("Sending the following net gcm tag on CIO 0x%llx-%llx\n", ((uint64_t *)gcmTag)[0],
					// ((uint64_t *)gcmTag)[1]);
				}

				if (mbs->syncRemaining == 1 && nextChunkOffset == 0) {
					// can only do the send for the very last sync.
					ret = [mh->service sendAssignedDataChunkFrom:(mbs->baseBufferId + bufferIdx)
					                                    atOffset:ongoingOffset
					                                    withTags:gcmTag];
				} else {
					// do the broadcastAndSend combo
					ret = [mh->service sendAssignedDataChunkFrom:(mbs->baseBufferId + bufferIdx)
					                                    atOffset:ongoingOffset
					                                    withTags:gcmTag
					             andPrepareAssignedDataChunkFrom:(mbs->baseBufferId + nextBufferIdx)
					                                    atOffset:AppleCIOMeshUserClientInterface::PrepareFullBuffer];
				}

				if (ret == 0) {
					MESHLOG("Server interrupted while broadcasting %d at offset %lld (ret %d)\n",
					        (int)(mbs->baseBufferId + bufferIdx), ongoingOffset, ret);
					atomic_store(&mbs->broadcastActive, false);
					return EINTR;
				}
			}

			atomic_fetch_add(&mbs->bufferInfo[bufferIdx].sentSize, mbs->chunkSize);
			ongoingOffset += mbs->chunkSize;
		}

		mbs->bufferInfo[mbs->curBufferIdx].performance.sendEndTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
		atomic_store(&mbs->bufferInfo[bufferIdx].blockSent, 1);
	} // move to the next partition section

	const uint64_t numExpectedReceives   = (getNodeCountFromMask(mbs->nodeMask) - 1) * sendCount;
	const auto expectedSectionsDecrypted = p2pMask ? 1 : partitionCount - 1;

	// wait for everything to be done. This is effectively the "all gather"
	while (true) {
		// spin waiting for the sync to complete
		if ((atomic_load(&mbs->bufferInfo[bufferIdx].chunkReceiveCount) == numExpectedReceives &&
		     atomic_load(&mbs->net_broadcast_chunk_count) == networkSendCount &&
		     atomic_load(&mbs->bufferInfo[bufferIdx].net_sections_decrypted) == expectedSectionsDecrypted) ||
		    atomic_load(&mh->reader_active) == 0 || atomic_load(&mbs->bufferInfo[bufferIdx].performance.numErrs) > 0) {
			break;
		}
		// printf("Spinning sendCount %d, expectedRx %d, actual sent %d, actual receive %d\n",
		// networkSendCount, numExpectedReceives, atomic_load(&mbs->net_broadcast_chunk_count),
		// atomic_load(&mbs->bufferInfo[bufferIdx].chunkReceiveCount));
	}

	const uint8_t participatingNodeCount = getNodeCountFromMask(mbs->nodeMask);

	if (mbs->bufferInfo[bufferIdx].performance.numErrs > 0 || atomic_load(&mh->reader_active) == 0) {
		uint64_t receivedMask = atomic_load(&mbs->bufferInfo[bufferIdx].blockReceiveMask);

		uint64_t expectedReceiveMaskPerNode = (0x1ull << (numExpectedReceives / (participatingNodeCount - 1))) - 1;

		os_log_error(mh->stats.logHandle,
		             "BroadcastAndGather - failing because of errors (%d, bufferIdx %d). Received: %d/%lld. Mask: 0x%llx\n",
		             mbs->bufferInfo[bufferIdx].performance.numErrs, bufferIdx,
		             atomic_load(&mbs->bufferInfo[bufferIdx].chunkReceiveCount), numExpectedReceives, receivedMask);

		for (auto nodeRankI = 0u; nodeRankI < mh->extendedNodeCount; nodeRankI++) {
			if (!isNodeParticipating(nodeRankI, mbs->nodeMask)) {
				continue;
			}

			uint64_t actualNodeIdx = getBufferOffsetForNode(calculateLocalNodeMask(mbs->nodeMask, mh, false), (uint8_t)nodeRankI);
			uint64_t expectedReceiveMaskForNode = expectedReceiveMaskPerNode
			                                      << (actualNodeIdx * __builtin_popcountll(expectedReceiveMaskPerNode));

			if ((nodeRankI != mh->myNodeId) && (receivedMask & expectedReceiveMaskForNode) != expectedReceiveMaskForNode) {
				os_log_error(mh->stats.logHandle, "BroadcastAndGather - failed to receive all data from node: %d [0x%llx]\n",
				             nodeRankI,
				             (receivedMask & expectedReceiveMaskPerNode) >>
				                 (actualNodeIdx * __builtin_popcountll(expectedReceiveMaskPerNode)));
			}

			receivedMask >>= (numExpectedReceives / (participatingNodeCount - 1));
		}

		atomic_store(&mbs->broadcastActive, false);
		return EINTR;
	}

	// this sync iteration is done.
	update_stats(mh, mbs);

	bufferIdx = mbs->curBufferIdx;

	atomic_store(&mbs->bufferInfo[bufferIdx].net_sections_decrypted, 0);
	atomic_store(&mbs->bufferInfo[bufferIdx].sectionsReady, 0);
	atomic_store(&mbs->net_broadcast_chunk_count, 0);
	mbs->bufferInfo[bufferIdx].chunkReceiveCount = 0;
	mbs->bufferInfo[bufferIdx].blockReceiveMask  = 0x0;
	mbs->bufferInfo[bufferIdx].blockSent         = 0;
	mbs->bufferInfo[bufferIdx].sentSize          = 0;

	mbs->bufferInfo[bufferIdx].performance.receivedStartTime = 0;
	mbs->bufferInfo[bufferIdx].performance.receivedEndTime   = 0;
	mbs->bufferInfo[bufferIdx].performance.sendStartTime     = 0;
	mbs->bufferInfo[bufferIdx].performance.sendEndTime       = 0;
	mbs->bufferInfo[bufferIdx].performance.iterId            = 0;
	mbs->bufferInfo[bufferIdx].performance.numErrs           = 0;

	ret = 0;

	// Wait until the last decryption thread (or the network thread) advances the current bufferIdx
	if (mbs->numBuffers > 1) {
		// network p2p do not require the driver bits, so they can use a single buffer.
		while (atomic_load(&mbs->currentReadIdx) == bufferIdx) {
			sched_yield();
		}
	}

	bufferIdx         = (bufferIdx + 1) % mbs->numBuffers;
	mbs->curBufferIdx = bufferIdx;

	MeshBufferState_t * nextMBS = nullptr;
	uint64_t nextMBSBaGCount    = 0;

	if (mbs->syncRemaining >= 1) {
		mbs->syncRemaining--;
		// Reset activate chained buffers to NULL once all the syncs are done.
		if (mbs->syncRemaining == 0) {
			// Check if there is a plan in place
			// If there is a plan, we will increment the curIdx, and see if there is another
			// BAG assignment that needs to happen
			// If we reached the end, let's clear the plan from all MeshBuffers so no one
			// tries to increment past the end.
			if (mbs->plan != nullptr) {
				mbs->plan->curIdx = mbs->plan->curIdx + 1;
				if (mbs->plan->curIdx < mbs->plan->execCount) {
					nextMBS         = mbs->plan->execPlan[mbs->plan->curIdx].mbs;
					nextMBSBaGCount = mbs->plan->execPlan[mbs->plan->curIdx].maxReads;
				} else {
					CHECK(mbs->plan->curIdx == mbs->plan->execCount, "CurrentPlanIdx: %zu, planCount: %zu, this is not possible",
					      mbs->plan->curIdx, mbs->plan->execCount);

					// Reached the end of the plan
					MESHLOG("Finished plan!");

					// Go through all the MBS and remove the active plan from them.
					// Ideally this shouldn't be done here since it would unnecessarily add to the BAG time
					// But it's fine...
					auto tmpPlan = mbs->plan;
					for (size_t i = 0; i < tmpPlan->execCount; i++) {
						tmpPlan->execPlan[i].mbs->plan = nullptr;
					}
					tmpPlan->execCount = 0;
					tmpPlan->curIdx    = 0;
				}
			}

			atomic_store(&mh->activateChainedBuffers, NULL);
		}
	}

	if (mh->verbose_level >= LogSignposts) {
		os_signpost_interval_end(mh->stats.broadcastAndGatherIntervalSignpost, OS_SIGNPOST_ID_EXCLUSIVE, "CIOMesh",
		                         "BaG iteration %lld, mask %llx, blockSize %llu", mbs->curIteration, mbs->nodeMask, mbs->blockSize);
		os_signpost_event_emit(mh->stats.logHandle, mh->stats.broadcastCompleteSignpost, "broadcastComplete", "iteration %lld",
		                       mbs->curIteration);
	}

	// increment the current iteration of the mesh buffer state.
	mbs->curIteration++;

	if (mh->verbose_level >= LogDebug) {
		MESHLOG("done with iteration %lld, bufferIdx is now %d\n", mbs->curIteration, (int)bufferIdx);
	}

	atomic_store(&mbs->broadcastActive, false);
	if (nextMBS != nullptr) {
		// if we have another buffer in the set, then assign the readers to it.
		MeshAssignBuffersToReaders_Private(mh, nextMBS, nextMBSBaGCount);
	}
	return ret;
}

extern "C" int
MeshAssignBuffersToReadersBulk(MeshHandle_t * mh, MeshExecPlan_t * plan, size_t planCount)
{
	if (planCount == 0) {
		MESHLOG_STR("Execplan must contain at least 1.");
		return 0;
	}

	if (mh->activePlan.curIdx != mh->activePlan.execCount) {
		MESHLOG_STR("Cannot execute 2 plans at once, please finish the prior one.");
		return 0;
	}

	mh->activePlan.curIdx    = 0;
	mh->activePlan.execCount = planCount;
	if (mh->activePlan.execPlan != nullptr) {
		free(mh->activePlan.execPlan);
	}
	mh->activePlan.execPlan = (MeshExecPlan_t *)calloc(planCount, sizeof(MeshExecPlan_t));

	// Copy the plan.
	memcpy(mh->activePlan.execPlan, plan, planCount * (sizeof(MeshExecPlan_t)));

	for (size_t i = 0; i < planCount; i++) {
		plan[i].mbs->plan = &mh->activePlan;
	}

	return MeshAssignBuffersToReaders(mh, plan[0].mbs, (int64_t)plan[0].maxReads);
}

extern "C" int
MeshAssignBuffersToReaders(MeshHandle_t * mh, MeshBufferState_t * mbs, int64_t maxReads)
{
	if (maxReads <= 0) {
		MESHLOG_STR("Max reads has to be greater than 0\n");
		return EINVAL;
	}

	return MeshAssignBuffersToReaders_Private(mh, mbs, maxReads);
}

extern "C" int
MeshAssignBuffersToReaders_Private(MeshHandle_t * mh, MeshBufferState_t * mbs, int64_t maxReads)
{
	const auto readIdx       = atomic_load(&mbs->currentReadIdx);
	int expectedPendingState = NoAssignment;
	if (!atomic_compare_exchange_strong(&mh->pendingMBSAssignmentState, &expectedPendingState, PendingAssignment)) {
		MESHLOG_STR("Assignment in progress\n");
		return EINPROGRESS;
	}

	if (MeshBufferState_t * tmp = (MeshBufferState_t *)atomic_load(&mh->activateChainedBuffers)) {
		MESHLOG("Assigning multiple buffers to readers. Previous BufferId:0x%llx, New BufferId:0x%llx\n", tmp->baseBufferId,
		        mbs->baseBufferId);
		return EINPROGRESS;
	}

	mh->pendingMBSAssignBuffer = mbs;
	mh->pendingMaxReadAssign   = maxReads;
	atomic_store(&mh->startReadChainedBuffers, 0);
	expectedPendingState = PendingAssignment;
	if (!atomic_compare_exchange_strong(&mh->pendingMBSAssignmentState, &expectedPendingState, StartAssignment)) {
		MESHLOG("Failed to set pending assignment state to 'StartAssignment'");
		return EINPROGRESS;
	}

	auto kr = semaphore_signal(mh->threadLeaderGoSignal[mh->syncGoIdx % THREAD_GO_SIGNAL_COUNT]);
	if (kr != KERN_SUCCESS) {
		MESHLOG_STR("Failed to signal leader thread sync go signal\n");
		return EIO;
	}

	mh->syncGoIdx++;
	const bool p2pMask = isP2PMask(mbs->nodeMask, mh->partitionIdx);

	if (mh->peerConnectionInfo) {
		bzero(mh->crypto.net_tx_tag_ptr, sizeof(mh->crypto.net_tx_tag_ptr));

		for (uint32_t i = 0; i < mbs->numBuffers; i++) {
			atomic_store(&mbs->bufferInfo[i].sectionsReady, 0);
			atomic_store(&mbs->bufferInfo[i].net_sections_decrypted, 0);
		}

		// For networking we do not need to "prepare" buffers before sending.
		// This means, at assignment time we can tell the networking threads
		// The MBS they will work on for the next N broadcast and gathers
		// as well as the buffer index within the MBS they will start the N
		// BAGs.

		atomic_store(&mh->crypto.assigned_bufferIdx_net, readIdx);
		atomic_store(&mh->crypto.assigned_syncCount_net, maxReads);
		atomic_store(&mh->crypto.assigned_mbs_net, (uintptr_t)mbs);

		// Wake the multi-partition receiver thread if this buffer involves more than
		// one partition (and is not p2p).
		const uint8_t participatingNodeCount = getNodeCountFromMask(mbs->nodeMask);
		if (participatingNodeCount > kMaxCIOMeshNodes) {
			kr = semaphore_signal(mh->netReceiveMultiPartitionGoSignal);
			if (kr != KERN_SUCCESS) {
				MESHLOG("Failed to signal network multi-partition receiver thread signal\n");
				return EIO;
			}
			kr = semaphore_signal(mh->netSendMultiPartitionGoSignal);
			if (kr != KERN_SUCCESS) {
				MESHLOG("Failed to signal network multi-partition sender thread signal\n");
				return EIO;
			}
		} else if (p2pMask) {
			// Activate the p2p network threads now.
			kr = semaphore_signal(mh->netSendPeerGoSignal);
			if (kr != KERN_SUCCESS) {
				MESHLOG_STR("Failed to signal network sender thread signal\n");
				return EIO;
			}

			kr = semaphore_signal(mh->netReceivePeerGoSignal);
			if (kr != KERN_SUCCESS) {
				MESHLOG_STR("Failed to signal network receiver thread signal\n");
				return EIO;
			}
		}
	}

	return 0;
}

// MARK: - Send To All / Scatter To All

extern "C" int
MeshSetupSendToAllBuffer(MeshHandle_t * mh, const uint64_t sendToAllBufferId, void * sendToAllBuf, uint64_t sendToAllBufSize)
{
	auto node_mask = createAllEnsembleMask(mh);
	return MeshSetupSendToAllBufferEx(mh, node_mask, sendToAllBufferId, sendToAllBuf, sendToAllBufSize);
}

extern "C" int
MeshSetupSendToAllBufferEx(MeshHandle_t * mh,
                           const uint64_t nodeMask,
                           const uint64_t sendToAllBufferId,
                           [[maybe_unused]] void * sendToAllBuf,
                           uint64_t sendToAllBufSize)
{
	uint64_t chunkSize = sendToAllBufSize > kMaxBlockSize ? kMaxBlockSize : sendToAllBufSize;

	// we need the buffer to be a multiple of the chunk size
	uint64_t totalBufferSize = ((sendToAllBufSize + chunkSize - 1) / chunkSize) * chunkSize;
	void * buff              = malloc(totalBufferSize);

	SendToAllBuffersArray_t * sendToAllBuffers = &mh->sendToAllBuffers;
	uint64_t index                             = sendToAllBuffers->arraySize;

	if (index >= MAX_SEND_TO_ALL_BUFFS) {
		MESHLOG("Already allocated %d send to all buffers, which is the max", MAX_SEND_TO_ALL_BUFFS);
		return EINVAL;
	}

	// Get the current send to all buffer from the aray
	SendToAllBuffer_t * sendToAllBuffer = &sendToAllBuffers->sendToAllBuffersArray[index];
	sendToAllBuffer->shadow             = buff;
	sendToAllBuffer->totalBufSize       = totalBufferSize;
	sendToAllBuffer->chunkSize          = chunkSize;
	sendToAllBuffer->numChunks          = totalBufferSize / chunkSize;
	sendToAllBuffer->sendtoallmask      = nodeMask;
	sendToAllBuffer->bufferId           = sendToAllBufferId;

	// Increment the array size for next call to send to all
	sendToAllBuffers->arraySize++;

	int64_t singleCommand[MAX_BREAKDOWN_COUNT] = {0};
	singleCommand[0]                           = chunkSize / mh->chunkDivider;

	if (![mh->service allocateSharedMemory:sendToAllBufferId
	                             atAddress:(mach_vm_address_t)sendToAllBuffer->shadow
	                                ofSize:totalBufferSize
	                         withChunkSize:chunkSize
	                        withStrideSkip:0
	                       withStrideWidth:0
	                  withCommandBreakdown:singleCommand]) {
		MESHLOG("AppleCIOMesh: failed to allocate sendToAll w/size %lld\n", totalBufferSize);

		return ENOMEM;
	}

	const uint32_t leaderNodeId      = (uint32_t)__builtin_ctzll(nodeMask);
	const uint32_t localLeaderNodeId = leaderNodeId % 8;
	const auto myLocalNodeId         = mh->myNodeId % 8;

	NodeAssignment_t assignment;
	assignment = mh->assignments[localLeaderNodeId];

	uint64_t outputMask = calculateLocalNodeMask(nodeMask, mh, true /* excludeSelf */);
	for (uint64_t chunk = 0; chunk < sendToAllBuffer->numChunks; chunk++) {
		uint64_t offset = chunk * chunkSize;
		// On extended ensembles, the leader will have a corresponding network-connected peer in the other partition
		// which acts as a CIO leader.
		if (myLocalNodeId == localLeaderNodeId) {
			// then we have to assign the entire chunk as an outgoing buffer
			[mh->service assignSharedMemory:sendToAllBufferId
			                       atOffset:offset
			                         ofSize:sendToAllBuffer->chunkSize
			         toOutgoingMeshChannels:outputMask
			                 withAccessMode:0x2
			                       fromNode:localLeaderNodeId];
		} else {
			// we're not the leader so the whole chunk is an incoming buffer
			if (assignment.inputChannel != -1) {
				[mh->service assignSharedMemory:sendToAllBufferId
				                       atOffset:offset
				                         ofSize:sendToAllBuffer->chunkSize
				          toIncomingMeshChannel:(uint64_t)assignment.inputChannel
				                 withAccessMode:0x2
				                       fromNode:localLeaderNodeId];
			}

			if (assignment.outputChannelCount > 0) {
				if (assignment.inputChannel != -1) {
					// if we will also forward what we receive, we should exclude the sender from the mask.
					uint64_t senderNode = 1u << assignment.localNodeRank;
					outputMask &= ~senderNode;
				}

				[mh->service assignSharedMemory:sendToAllBufferId
				                       atOffset:offset
				                         ofSize:sendToAllBuffer->chunkSize
				         toOutgoingMeshChannels:outputMask
				                 withAccessMode:0x2
				                       fromNode:assignment.localNodeRank];
			}
		}
	}

	// override runtime prepare in case it was set to true. Runtime prepare is needed
	// for large buffer sizes during broadcast and gather. It is not needed
	// for large buffer sizes during send to all because the framework will
	// divide the buffer into smaller chunks and prepare one chunk at at time.
	// If runtime prepare is enabled, this leads to a double prepare and also a panic.
	[mh->service overrideRuntimePrepareFor:sendToAllBufferId];

	return 0;
}

extern "C" int
MeshSetupScatterToAllBuffer(MeshHandle_t * mh, uint64_t scatterBufferId, void * scatterBuf, uint64_t scatterBufSize)
{
	bool ret                       = false;
	uint64_t scatterToAllBlockSize = scatterBufSize / mh->localNodeCount;

	int64_t singleCommand[MAX_BREAKDOWN_COUNT] = {0};
	singleCommand[0]                           = (int64_t)scatterToAllBlockSize / mh->chunkDivider;
	if (![mh->service allocateSharedMemory:scatterBufferId
	                             atAddress:(mach_vm_address_t)scatterBuf
	                                ofSize:scatterBufSize
	                         withChunkSize:scatterToAllBlockSize
	                        withStrideSkip:0
	                       withStrideWidth:0
	                  withCommandBreakdown:singleCommand]) {
		MESHLOG("AppleCIOMesh: failed to allocate scatte w/size %lld\n", scatterBufSize);

		return ENOMEM;
	}

	NodeAssignment_t assignment;

	if (mh->myNodeId == mh->leaderNodeId) {
		uint64_t offset = 0;

		for (uint32_t peerId = 0; peerId < mh->localNodeCount; peerId++, offset += scatterToAllBlockSize) {
			if (peerId == mh->myNodeId) {
				continue;
			}

			assignment = mh->assignments[peerId];

			// assign this block to go to this specific peer
			bool ret;
			ret = [mh->service assignSharedMemory:scatterBufferId
			                             atOffset:offset
			                               ofSize:scatterToAllBlockSize
			               toOutgoingMeshChannels:(uint64_t)(1 << assignment.inputChannel)
			                       withAccessMode:0x2
			                             fromNode:mh->myNodeId];
			if (!ret) {
				MESHLOG("%s: Assigning offset 0x%llx to inputChannel %d failed\n", __FUNCTION__, offset, assignment.inputChannel);
			}
		}
	} else {
		// we're not the leader so only one chunk is coming to us from the leaderNode
		uint64_t offset = (mh->myNodeId * scatterToAllBlockSize);

		assignment = mh->assignments[mh->leaderNodeId];

		[mh->service assignSharedMemory:scatterBufferId
		                       atOffset:offset
		                         ofSize:scatterToAllBlockSize
		          toIncomingMeshChannel:(uint64_t)assignment.inputChannel
		                 withAccessMode:0x2
		                       fromNode:(mh->leaderNodeId)];
	}

	return ret;
}

extern "C" int
MeshReleaseBuffer(MeshHandle_t * mh, uint64_t bufferId, uint64_t bufferSize)
{
	SendToAllBuffer_t * sendToAllBuffer = lookupSendToAllBuffer(mh, bufferId);

	if (sendToAllBuffer == nullptr) {
		MESHLOG("No buffer with ID 0x%llx to deallocate\n", bufferId);
		return -1;
	}

	if ([mh->service deallocateSharedMemory:bufferId ofSize:sendToAllBuffer->totalBufSize] == NO) {
		MESHLOG("Failed to deallocate shared memory bufId 0x%llx size %lld\n", bufferId, bufferSize);
		return -1;
	}

	free(sendToAllBuffer->shadow);

	// to keep the array contiguous, move the last element to this spot
	if (mh->sendToAllBuffers.arraySize > 1) {
		SendToAllBuffer_t * lastBuffer = &mh->sendToAllBuffers.sendToAllBuffersArray[mh->sendToAllBuffers.arraySize - 1];
		*sendToAllBuffer               = *lastBuffer;

		// clear out the last buffer
		lastBuffer->shadow        = 0;
		lastBuffer->bufferId      = 0;
		lastBuffer->chunkSize     = 0;
		lastBuffer->sendtoallmask = 0;
		lastBuffer->totalBufSize  = 0;
	}

	// decrement the size of the array.
	mh->sendToAllBuffers.arraySize--;

	return 0;
}

extern "C" bool
MeshSendToAllPeers(MeshHandle_t * mh, const uint64_t sendToAllBufferId, void * sendToAllBuf, uint64_t sendToAllBufSize)
{
	SendToAllBuffer_t * sendToAllBuffer = lookupSendToAllBuffer(mh, sendToAllBufferId);

	if (sendToAllBuffer == nullptr) {
		MESHLOG("No buffer with ID 0x%llx to deallocate\n", sendToAllBufferId);
		return false;
	}

	uint64_t numChunks = sendToAllBuffer->numChunks;
	uint64_t chunkSize = sendToAllBuffer->chunkSize;
	bool ret           = false;

	MeshCryptoKeyState_t * keyState = lookupKeyFromMask(mh, sendToAllBuffer->sendtoallmask);
	CHECK(keyState != nullptr, "No key generated for this mask 0x%llx. Aborting", sendToAllBuffer->sendtoallmask);
	AppleCIOMeshNet::TcpConnection * tcpConnection = nullptr;
	if (mh->peerConnectionInfo && sendToAllBuffer->sendtoallmask == 0xFFFF) {
		tcpConnection = &mh->peerConnectionInfo[0].tx_connection.value();
	}

	for (uint64_t chunk = 0; chunk < numChunks; chunk++) {
		uint64_t offset = chunk * chunkSize;
		ret             = [mh->service prepareDataChunkTransferFor:sendToAllBufferId atOffset:offset];
		if (!ret) {
			MESHLOG("Failed to prepare outgoing buffer for bufferId 0x%llx : ret=%d\n", sendToAllBufferId, ret);
			return false;
		}

		char tag[2][kTagSize];

		if (mh->cryptoKeyArray.key_count == 0) {
			os_log_error(OS_LOG_DEFAULT,
			             "MeshSendToAllPeers: Crypto key not set when preparing outgoing buffer for bufferId 0x%llx\n",
			             sendToAllBufferId);
			return false;
		}

#ifdef DEBUG_SIGNPOSTS
		//		if (mh->verbose_level >= LogSignposts) {
		//			os_signpost_event_emit(mh->stats.logHandle, mh->stats.cryptoSignpost, "cryptoSenderEnc", "sendToAll %llu sz
		//%lld",								   sendToAllBufferId, sendToAllBufSize);
		//		}
#endif
		// if we are on the last chunk and it's not a full chunk size
		uint64_t transferSize = chunkSize;
		if ((chunk == numChunks - 1) && (sendToAllBufSize % chunkSize > 0)) {
			transferSize = sendToAllBufSize % chunkSize;
		}

		// encrypting data from the user's buffer and storing it in the buffer
		// we allocated in shared memory.
		void * srcChunk = (char *)sendToAllBuf + offset;
		void * dstChunk = (char *)sendToAllBuffer->shadow + offset;
		int err         = aes_gcm_encrypt_memory(keyState->crypto_key[mh->myNodeId], keyState->crypto_key_sz,
		                                         &keyState->crypto_node_iv[mh->myNodeId], srcChunk, transferSize, dstChunk, &tag[0][0],
		                                         kTagSize, mh->myNodeId);

		memcpy(&tag[1][0], &tag[0][0], kTagSize);
		if (err != 0) {
			os_log_error(OS_LOG_DEFAULT, "Failed to encrypt sendToAll buffer\n");
			return false;
		}

		// TODO (marco): this can be done async (use non-blocking IO)
		if (tcpConnection) {
			MESHLOG("NodeId: %d - Sending chunk with tag: 0x%llx-%llx\n", mh->myNodeId, ((uint64_t *)tag)[0], ((uint64_t *)tag)[1]);
			const auto [written, err] = tcpConnection->write((uint8_t *)dstChunk, transferSize);
			if (written < 0) {
				MESHLOG("Failed to send payload to network. Error: %s\n", strerror(err));
				atomic_store(&mh->reader_active, 0);
				break;
			}
			if (written == 0) {
				MESHLOG("Peer disconnected unexpectedly.");
				atomic_store(&mh->reader_active, 0);
				break;
			}
			// Write the tag
			const auto [tagWritten, tagErr] = tcpConnection->write((uint8_t *)&tag[0][0], kTagSize);
			if (tagWritten < 0) {
				MESHLOG("Failed to send tag to network. Error: %s\n", strerror(tagErr));
				atomic_store(&mh->reader_active, 0);
				break;
			}
			if (tagWritten == 0) {
				MESHLOG("Peer disconnected unexpectedly.");
				atomic_store(&mh->reader_active, 0);
				break;
			}
		}

		ret = [mh->service sendAssignedDataChunkFrom:sendToAllBufferId atOffset:offset withTags:&tag[0][0]];
		if (!ret) {
			MESHLOG("Failed to broadcast outgoing buffer for bufferId 0x%llx at offset %llu: ret=%d\n", sendToAllBufferId, offset,
			        ret);
			return false;
		}
	}

#ifdef DEBUG_SIGNPOSTS
	//		if (mh->verbose_level >= LogSignposts) {
	//			os_signpost_event_emit(mh->stats.logHandle, mh->stats.cryptoSignpost, "cryptoSenderDec", "sendToAll %llu sz %lld",
	//								   sendToAllBufferId, sendToAllBufSize);
	//		}
#endif

	return ret;
}

extern "C" bool
MeshScatterToAll(MeshHandle_t * mh, uint64_t bufferId, void * scatterBuf, uint64_t scatterBufSize)
{
	return true;
}

extern "C" int
MeshReceiveFromLeader(MeshHandle_t * mh, uint64_t bufferId, void * bufPtr, uint64_t bufSize, uint64_t offset)
{
	return MeshReceiveFromLeaderEx(mh, 0, bufferId, bufPtr, bufSize, offset);
}

extern "C" int
MeshReceiveFromLeaderEx(
    MeshHandle_t * mh, uint32_t leaderNodeId, uint64_t bufferId, void * bufPtr, uint64_t bufSize, uint64_t offset)
{
	SendToAllBuffer_t * sendToAllBuffer = lookupSendToAllBuffer(mh, bufferId);

	if (sendToAllBuffer == nullptr) {
		MESHLOG("No buffer with ID 0x%llx to deallocate\n", bufferId);
		return false;
	}

	uint64_t numChunks              = sendToAllBuffer->numChunks;
	uint64_t chunkSize              = sendToAllBuffer->chunkSize;
	MeshCryptoKeyState_t * keyState = lookupKeyFromMask(mh, sendToAllBuffer->sendtoallmask);
	if (keyState == NULL) {
		MESHLOG("NO key generated for this mask 0x%llx", sendToAllBuffer->sendtoallmask);
		return false;
	}

	const auto leaderPartitionIdx                  = leaderNodeId / 8u;
	AppleCIOMeshNet::TcpConnection * tcpConnection = nullptr;
	// if I'm on the same partition as the sender, then receive over CIO.
	if (mh->partitionIdx != leaderPartitionIdx) {
		// I'm on a different partition than the sender.
		CHECK(sendToAllBuffer->sendtoallmask == 0xFFFF, "only 0xFFFF is supported for extended ensembles.");
		if (areNetworkPeers(mh->myNodeId, leaderNodeId)) {
			tcpConnection = &mh->peerConnectionInfo[0].rx_connection.value();
		}
	}

	for (uint64_t chunk = 0; chunk < numChunks; chunk++) {
		const uint64_t totalOffset = offset + (chunk * chunkSize);

		// if we are on the last chunk and it's not a full chunk size
		uint64_t transferSize = chunkSize;
		if ((chunk == numChunks - 1) && (bufSize % chunkSize > 0)) {
			transferSize = bufSize % chunkSize;
		}

		// if I'm the network peer of the leader, then receive over network.
		if (tcpConnection) {
			auto * srcPtr                    = (uint8_t *)sendToAllBuffer->shadow + totalOffset;
			const auto [chunkRead, chunkErr] = tcpConnection->read(srcPtr, transferSize);
			if (chunkRead < 0) {
				MESHLOG("Failed to receive payload from network. Error: %s\n", strerror(chunkErr));
				atomic_store(&mh->reader_active, 0);
				return false;
			}
			if (chunkRead == 0) {
				MESHLOG("Peer disconnected unexpectedly.");
				atomic_store(&mh->reader_active, 0);
				return false;
			}

			char rxtags[2][kTagSize];
			// receive the tag
			const auto [tagRead, tagErr] = tcpConnection->read((uint8_t *)rxtags[0], kTagSize);
			if (tagRead < 0) {
				MESHLOG("Failed to receive tag from network: Error: %s\n", strerror(tagErr));
				atomic_store(&mh->reader_active, 0);
				return false;
			}
			if (tagRead == 0) {
				MESHLOG("Peer disconnected unexpectedly.");
				atomic_store(&mh->reader_active, 0);
				return false;
			}

			memcpy(&rxtags[1][0], &rxtags[0][0], kTagSize);

			// Decrypt the data for the current node.
			void * dstPtr = (char *)bufPtr + totalOffset;
			int cstat     = aes_gcm_decrypt_memory(keyState->crypto_key[leaderNodeId], keyState->crypto_key_sz,
			                                       &keyState->crypto_node_iv[leaderNodeId], srcPtr, transferSize, dstPtr, rxtags[0],
			                                       sizeof(rxtags[0]), leaderNodeId, 0);
			if (cstat != 0) {
				return false;
			}
			keyState->crypto_node_iv[leaderNodeId].count++;

			// Send the data we received from the socket over cio to my partition only.
			// The data is already encrypted.
			bool ret = [mh->service prepareDataChunkTransferFor:bufferId atOffset:totalOffset];
			if (!ret) {
				MESHLOG("Failed to prepare outgoing buffer for bufferId 0x%llx : ret=%d\n", bufferId, ret);
				return false;
			}
			ret = [mh->service sendAssignedDataChunkFrom:bufferId atOffset:totalOffset withTags:rxtags[0]];
			if (!ret) {
				MESHLOG("Failed to broadcast outgoing buffer for bufferId 0x%llx at offset %llu: ret=%d\n", bufferId, offset, ret);
				return false;
			}

		} else {
			// receive from CIO only
			bool ret = [mh->service prepareDataChunkTransferFor:bufferId atOffset:totalOffset];
			if (!ret) {
				MESHLOG("Failed to prepare incoming buffer for bufferId 0x%llx : ret=%d\n", bufferId, ret);
				return false;
			}

			char tag[kTagSize];
			ret = [mh->service waitOnSharedMemory:bufferId atOffset:totalOffset withTag:tag];
			if (!ret) {
				MESHLOG("Failed to receive incoming buffer for bufferId 0x%llx : ret=%d\n", bufferId, ret);
				return false;
			}

			if (mh->cryptoKeyArray.key_count == 0) {
				os_log_error(OS_LOG_DEFAULT,
				             "MeshReceiveFromLeader: Crypto key not set when preparing outgoing buffer for bufferId 0x%llx\n",
				             bufferId);
				return false;
			}

#ifdef DEBUG_SIGNPOSTS
			//		if (mh->verbose_level >= LogSignposts) {
			//			os_signpost_event_emit(mh->stats.logHandle, mh->stats.cryptoSignpost, "cryptoReceiverDec", "sendToAll %llu
			// sz %lld",								   bufferId, bufSize);
			//		}
#endif
			void * dstPtr = (void *)((char *)bufPtr + totalOffset);
			void * srcPtr = (void *)((char *)sendToAllBuffer->shadow + totalOffset);
			int cstat     = aes_gcm_decrypt_memory(keyState->crypto_key[leaderNodeId], keyState->crypto_key_sz,
			                                       &keyState->crypto_node_iv[leaderNodeId], srcPtr, transferSize, dstPtr, tag,
			                                       sizeof(tag), leaderNodeId, 0);
			keyState->crypto_node_iv[leaderNodeId].count++;
			if (cstat != 0) {
				os_log_error(OS_LOG_DEFAULT, "decrypt failed: cstat %d; tag: 0x%llx 0x%llx\n", cstat, ((uint64_t *)&tag[0])[0],
				             ((uint64_t *)&tag[0])[1]);
				return false;
			}
		}
	}
	return true;
}

// MARK: - Barrier

static void *
allocateBuffer(uint64_t bufferSize)
{
	mach_vm_address_t buffer = 0;

	kern_return_t kr = mach_vm_allocate(mach_task_self(), &buffer, bufferSize, VM_FLAGS_ANYWHERE);
	if (kr != KERN_SUCCESS) {
		MESHLOGx("failed to allocate memaligned buffer\n");
		return NULL;
	}

	return (void *)buffer;
}

extern "C" int
MeshBarrier(MeshHandle_t * mh)
{
	uint32_t barrierBufferId  = 0x123456;
	uint64_t barrierBlockSize = 16384;
	uint64_t barrierBufSize   = mh->localNodeCount * barrierBlockSize;
	void * ptrs[1];
	MeshBufferState_t * mbs;
	uint8_t verify_base_val = (uint8_t)(barrierBufferId << 4) | 0x80;
	int ret;

	ptrs[0] = allocateBuffer(barrierBufSize);
	if (ptrs[0] == NULL) {
		MESHLOG_STR("No memory for barrier buffer.\n");
		return ENOMEM;
	}

	unsigned char * p = (unsigned char *)ptrs[0];
	for (uint32_t i = 0; i < mh->localNodeCount; i++) {
		char val;
		if (i == mh->myNodeId) {
			val = (verify_base_val | (uint8_t)mh->myNodeId);
		} else {
			val = 0x55;
		}
		memset(&p[i * barrierBlockSize], val, barrierBlockSize);
	}

	ret = MeshSetupBuffers(mh, barrierBufferId, barrierBufSize, barrierBlockSize, barrierBlockSize, ptrs, 1, &mbs);
	if (ret != 0) {
		return ret;
	}

	if (auto result = MeshAssignBuffersToReaders(mh, mbs, 1); 0 != result) {
		os_log_error(OS_LOG_DEFAULT, "AppleCIOMesh: Failed to assign buffers to readers: [0x%x]", result);
		return result;
	}

	int r = MeshBroadcastAndGather(mh, mbs);
	if (r != 0) {
		MESHLOG("Barrier BroadcastAndGather failed!  r=%d\n", r);
	}

	for (uint32_t i = 0; i < mh->localNodeCount; i++) {
		if (p[i * barrierBlockSize] != (verify_base_val | i)) {
			MESHLOG("Barrier sync failed.  Did not receive data from node %d (expected val: 0x%x, got 0x%x) r=%d\n", i,
			        (verify_base_val | i), *(uint32_t *)&p[i * barrierBlockSize], r);
			if (!r) {
				r = EINVAL;
			}
		}
	}

	MeshReleaseBuffers(mh, mbs);
	mach_vm_deallocate(mach_task_self(), (mach_vm_address_t)ptrs[0], barrierBufSize);

	return r;
}

// MARK: - Private testing functions

extern "C" int
MeshCopyMyChunkToAllSections_private(MeshHandle_t * mh, MeshBufferState_t * mbs, uint8_t chunkIdx, char * tag)
{
	const auto localNodeId      = mh->myNodeId % 8;
	const uint8_t localMask     = calculateLocalNodeMask(mbs->nodeMask, mh, false /* excludeSelf */);
	const auto srcSectionOffset = getSectionOffsetForPartition(mbs->nodeMask, mh->partitionIdx);
	const auto blockOffset      = getBufferOffsetForNode(localMask, localNodeId);

	const auto partitionCount = getPartitionCountFromMask(mbs->nodeMask);
	uint64_t bufferIdx        = mbs->curBufferIdx;

	auto * bufPtr = mbs->bufferInfo[bufferIdx].shadow;
	int ret       = 0;

	uint64_t srcOffset = (mbs->chunkSize * chunkIdx) + (mbs->blockSize * blockOffset) + (mbs->sectionSize * srcSectionOffset);

	// start from the next partition
	uint8_t pIdx = (mh->partitionIdx + 1) % partitionCount;

	// We need to copy the tags, but the API is doing encryption as well, so
	// we will copy that in MeshBroadcastAndGather.
	uint8_t sectionCount = 0;
	for (; sectionCount < partitionCount - 1; pIdx = (pIdx + 1) % partitionCount, sectionCount++) {
		const auto dstSectionOffset = getSectionOffsetForPartition(mbs->nodeMask, pIdx);
		uint64_t dstOffset = (mbs->chunkSize * chunkIdx) + (mbs->blockSize * blockOffset) + (mbs->sectionSize * dstSectionOffset);

		memcpy((uint8_t *)bufPtr + dstOffset, (uint8_t *)bufPtr + srcOffset, mbs->chunkSize);

		ret++;

		// We "received" the chunk for the network nodes (we're sending it!)
		atomic_fetch_add(&mbs->bufferInfo[bufferIdx].chunkReceiveCount, 1);

		// Copy the tag too -- for both links.
		memcpy(mbs->bufferInfo[bufferIdx].netSectionRxTag[sectionCount + 1][(chunkIdx * mh->chunkDivider) + 0], tag, kTagSize);
		memcpy(mbs->bufferInfo[bufferIdx].netSectionRxTag[sectionCount + 1][(chunkIdx * mh->chunkDivider) + 1], tag, kTagSize);
	}
	atomic_store(&mbs->bufferInfo[bufferIdx].sectionsReady, sectionCount);
	return ret;
}

extern "C" void
MeshSetupBufferForSelfCopy_private(MeshHandle_t * mh, MeshBufferState_t * mbs)
{
	mbs->test_CopyTagsForNetRx = true;

	const auto partitionCount = getPartitionCountFromMask(mbs->nodeMask);

	for (unsigned i = 0; i < kMaxCIOMeshNodes; i++) {
		for (unsigned p = 0; p < partitionCount; p++) {
			if (p == mh->partitionIdx) {
				continue;
			}

			auto nodeIdx            = (p * kMaxCIOMeshNodes) + i;
			auto myPartitionNodeIdx = (mh->partitionIdx * kMaxCIOMeshNodes) + i;

			memcpy(mbs->assignedCryptoState->crypto_key[nodeIdx], mbs->assignedCryptoState->crypto_key[myPartitionNodeIdx],
			       MAX_CRYPTO_KEYSIZE);
			mbs->assignedCryptoState->crypto_node_iv[nodeIdx] = mbs->assignedCryptoState->crypto_node_iv[myPartitionNodeIdx];
		}
	}
}

extern "C" MeshHandle_t *
MeshCreateHandleWithPartition_private(uint32_t leaderNodeId, uint8_t partitionIdx)
{
	uint32_t myNodeId, numNodes;
	if (!MeshGetInfo(&myNodeId, &numNodes)) {
		return NULL;
	}

	// spin for 50ms
	uint64_t start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
	while ((clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) < (50 * 1000 * 1000)) {}

	return MeshCreate(myNodeId + (partitionIdx * kMaxCIOMeshNodes), numNodes, leaderNodeId, partitionIdx);
}

extern "C" int
MeshSetupBuffersHint(MeshHandle_t * mh, uint64_t bufferSize)
{
	mh->shadow_arena->lock(bufferSize);
	return 0;
}
