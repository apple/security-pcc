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

#pragma once

#include <inttypes.h>
#include <os/signpost_private.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <sys/types.h>

#import <AppleCIOMeshSupport/AppleCIOMeshAPI.h>
#import <AppleCIOMeshSupport/AppleCIOMeshSupport.h>

#ifndef MAX_NODES_DEFINED
// NOTE:  this typically comes from Common/Config.h but during the build
// process there's a "GenerateTAPI" command that is run that can't include
// that file for some reason so we work-around it by defining it here if
// MAX_NODES_DEFINED is not defined
#define kMaxCIOMeshNodes 8
#define kMaxExtendedMeshNodes 32
#define kMaxPartitions 4
#endif

// The actual line rate of a CIO40 link is not 40Gbit as there is signaling
// overhead and bit expansion on the wire.  The actual rate works out to be
// approximately 38.2 Gbps
#define CIO40_ACTUAL_LINE_RATE (38200000000ULL)

// This should be enabled carefully --
// update_stats can deadlock itself when it resets the timestamp back to 0.
// It may end up reseting the future timestamp and then spin indefinitely.
// #define MESH_SKIP_LAST_GATHER_TIMESTAMP

#define MESH_SYNC_HISTOGRAM_COUNT 10
// Maximum number of subchunks each chunk can be broken down into for
// forwarding.
#define MAX_BREAKDOWN_COUNT (8)
// Leader node ID/rank.
#define MESH_DEFAULT_LEADER_NODE_ID 0
// Maximum number of crypto threads we'll allow.
#define MAX_CRYPTO_THREADS 8

// Maximum number of network peers
#define MAX_NET_PEERS 3

#define MAX_CRYPTO_KEYSIZE 16

// This should match kTagSize in Common/Config.h
#define TAG_SIZE 16

// The maximum number of chunks a block will be divided into. This needs to
// match the division in MeshSetupBuffers
#define MAX_CHUNKS_PER_BLOCK 128

// Number of signals to ping-pong over.
#define THREAD_GO_SIGNAL_COUNT 2

#define LARGE_MAX_COUNTER 100

#define MAX_NODE_MASKS 115

#define MAX_SEND_TO_ALL_BUFFS 8

// Maximum number of entries to keep in the buffer
#define RECENT_SYNC_CAPACITY 3000

/// Verbosity levels, these are cumulative.
typedef enum {
	LogStats     = 0x1,
	LogSignposts = 0x2,
	LogDebug     = 0x5,
} MeshVerbosityLevel_t;

/// Mesh assignment state to signal when a buffer should be assigned to the
/// readers.
typedef enum {
	NoAssignment      = 0x0, // idle
	PendingAssignment = 0x1,
	StartAssignment   = 0x2,
} MeshAssignmentState_t;

/// Each node's CIO assignment. Has information about where
/// the node's data is coming from, and/or going to.
typedef struct {
	// The node's rank.
	uint32_t localNodeRank;
	// The node's extended rank.
	uint32_t extendedNodeRank;
	// The input channel the node's data is coming from. For blocks the current
	// node is responsible for generating+broadcasting, this will be -1.
	int8_t inputChannel;
	// The output channels this node's data has to be sent on. If input channel
	// is -1 for this block, then this node is responsible for generating
	// and broadcasting the block. If input channel is not -1, then this
	// node will be receving the data, and will re-broadcast it on the
	// output channels.
	uint8_t outputChannels[8];
	// Number of output channels to broadcast on.
	uint8_t outputChannelCount;
} NodeAssignment_t;

/// CIO mesh buffer performance statistics.
typedef struct {
	uint64_t receivedStartTime;
	uint64_t receivedEndTime;
	uint64_t sendStartTime;
	uint64_t sendEndTime;
	uint64_t iterId;
	atomic_int numErrs;
	atomic_int lastNode;
} BufferPerformanceStats_t;

// forward declare to avoid clobbering whatever is generated from the framework
struct PeerConnectionInfo;
class MeshArena;

/// A CIO Mesh buffer.
typedef struct CIOBufferInfo {
	// Pointer to the user buffer.
	void * bufferPtr;
	// The buffer size.
	uint64_t bufferSize;
	// The section size.
	uint64_t sectionSize;
	// The total size each node will generate and send.
	uint64_t blockSize;
	// The size each node will send over time. This must evenly divide blockSize.
	uint64_t chunkSize;
	// The buffer used by the driver/framework.
	void * shadow;
	// The total number of bytes transferred.
	atomic_uint_fast64_t sentSize; // what a godawful type name!
	// The number of chunks received.
	atomic_int chunkReceiveCount;
	// Mask identifying which blocks have been received.
	atomic_uint_fast64_t blockReceiveMask;
	// Flag indicating if the block this node is responsible for has been sent.
	atomic_int blockSent;

	// This is an indicator of how many sections within the buffer has been
	// received from networking peers and are ready to send over CIO.
	atomic_uint sectionsReady;

	// Number of sections received over the network that have been decrypted.
	// This is incremented by the encryption thread (which happens to do decryption
	// for net received sections).
	atomic_int net_sections_decrypted;

	// This is where the tags will be stored when received from networking
	// peers. This field will be "gated" by sectionsReady.
	// The sequence of this array is the sequence broadcast and gather happens in
	// If I am partition 2, my BAG sequence is: section2, section3, section0, section1
	// We will still iterate over netSectionRxTag from 1,2,3 (skipping 0).
	// on partition2, [0] = empty, [1] = section3 Tag, [2] = section 0 tag, and so on.
	char netSectionRxTag[kMaxPartitions][MAX_CHUNKS_PER_BLOCK][TAG_SIZE];

	// Performance statistics for this buffer.
	BufferPerformanceStats_t performance;
} CIOBufferInfo_t;

// Per sync stats.
typedef struct RecentSyncStats {
	uint64_t nodeMask;
	uint64_t bufferSize;
	uint64_t endTime;
	uint64_t syncTime;
} RecentSyncStats_t;

typedef struct SyncStatsCircularQueue {
	RecentSyncStats_t buffer[RECENT_SYNC_CAPACITY];
	uint64_t endIndex;
	uint64_t count;
} SyncStatsCircularQueue_t;

/// Overall CIO mesh performance statistics.
typedef struct MeshStats {
	SyncStatsCircularQueue_t recentSyncs;
	uint64_t syncTotalTime;
	uint64_t syncMinTime;
	int64_t syncMinIter;
	uint64_t syncMaxTime;
	uint64_t syncCounter;
	uint64_t syncTimeHistogram[MESH_SYNC_HISTOGRAM_COUNT];
	uint64_t syncTimeHistogramBins[MESH_SYNC_HISTOGRAM_COUNT];
	uint64_t lastNodeToSyncCount[kMaxCIOMeshNodes]; // who was the last node to sync
	uint64_t lastLog;
	double totalIncomingCounter;
	int averageIncomingCounter;

	double averageOutgoingSpeed;
	double totalOutgoingCounter;
	double incomingSize;
	double outgoingSize;

	int averageOutgoingCounter;

	atomic_uint_fast64_t encrypt_total_time;
	atomic_uint_fast64_t num_encrypt;
	atomic_uint_fast64_t decrypt_total_time;
	atomic_uint_fast64_t num_decrypt;
	uint64_t cryptoWaitTotal;
	uint64_t cryptoWaitCount;

	os_log_t logHandle;
	os_log_t signpostHandle;
	os_log_t broadcastAndGatherIntervalSignpost; // interval
	os_signpost_id_t incomingDataSignpost;       // event
	os_signpost_id_t broadcastCompleteSignpost;  // evnet
	os_signpost_id_t longSyncSignpost;           // event
	os_signpost_id_t zeroSyncSignpost;           // event
	os_signpost_id_t cryptoSignpost;             // multiple events
	os_signpost_id_t threadAliveSignpost;
} MeshStats_t;

/// CIO Mesh buffer performance statistics.
typedef struct MeshBufferStats {
	uint64_t syncTotalTime;
	uint64_t syncCounter;
	uint64_t syncTimeHistogram[MESH_SYNC_HISTOGRAM_COUNT];
	uint64_t syncTimeHistogramBins[MESH_SYNC_HISTOGRAM_COUNT];
	uint64_t largeTimes[LARGE_MAX_COUNTER];
	uint64_t largeTimesIter[LARGE_MAX_COUNTER];
	uint64_t largeCounter;
} MeshBufferStats_t;

typedef struct MeshCryptoIV {
	uint64_t prefix;
	uint32_t count;
} __attribute__((packed)) MeshCryptoIV;

typedef struct MeshCryptoKeyState {
	uint8_t crypto_key[kMaxExtendedMeshNodes][MAX_CRYPTO_KEYSIZE];
	size_t crypto_key_sz;
	// these are the iv's for each node. Each crypto thread users their
	// associated IV.
	MeshCryptoIV crypto_node_iv[kMaxExtendedMeshNodes];
} MeshCryptoKeyState_t;

typedef struct {
	MeshExecPlan_t * execPlan;
	size_t execCount;
	size_t curIdx;
} MeshPlan_t;

/// A CIO Mesh buffer handle. This collects multiple CIO Mesh Buffers.
typedef struct MeshBufferState {
	// The base id of all CIO mesh buffers.
	uint64_t baseBufferId;
	// The current buffer being transferred (outgoing).
	uint32_t curBufferIdx;
	// Number of buffers in the full buffer state.
	uint32_t numBuffers;
	// The size of each individual mesh buffer.
	uint64_t bufferSize;
	// A buffer can be split into multiple sections if the mesh is extended
	// over multiple network-connected partitions.
	// Otherwise, its value is equal to the bufferSize.
	uint64_t sectionSize;
	// The number of bytes each node is responsible for and conributing to the
	// mesh buffer.
	uint64_t blockSize;
	// The size of each chunk within the block, the smallest unit of
	// communication.
	uint64_t chunkSize;
	// The user's buffer size. This may not match the buffer size for optimal
	// memory layout.
	uint64_t userBufferSize;
	uint64_t userBlockSize;
	uint64_t userChunkSize;
	uint64_t userSectionSize;
	// The breakdown of each chunk when forwarding. Each sub-chunk will be sent
	// as it is received. Too many sub-chunks can cause unnecessary overhead in
	// the driver so a good balance is needed between immediately sending after
	// receiving and buffering more Thunderbolt frames. Each sub-chunk has to be
	// a multiple of kMinTransferSize.
	int64_t forwardBreakdown[MAX_BREAKDOWN_COUNT];
	// The "chain" of forwards that the driver can run through to quickly prepare
	// the next chunk. It is recommended to use forward chaining to prepare
	// thunderbolt forwards similar to how input/output buffers are prepared.
	int64_t forwardChainId;
	// The number of broadcast and gather transfers remaining.
	int64_t syncRemaining;
	// Number of gathers remaining for the reader thread.
	atomic_int_fast64_t activeReadRemaining;
	// The start index for the reader thread.
	atomic_uint currentReadIdx;
	// An array of CIO mesh buffers.
	CIOBufferInfo_t * bufferInfo;
	// The current broadcast and gather transfer iteration.
	uint64_t curIteration;
	// If the first buffer has been prepared for output. The following buffers
	// will be prepared automatically after transfering the last buffer.
	atomic_bool firstPrepareDone;

	// The crypto keys assigned to this buffer.
	MeshCryptoKeyState_t * assignedCryptoState;

	// The bitmask identifying which nodes (by their rank) will exchange this buffer.
	uint64_t nodeMask;
	// The number of iterations we'll read this buffer
	// Never change the value of this member once assigned.
	uint64_t maxReads;
	// The plan that is being followed by the MeshBufferState
	MeshPlan_t * plan;
	// Whether this MBS is being broadcasted at a moment in time.
	atomic_bool broadcastActive;

	// Performance stats for  the buffer.
	MeshBufferStats_t stats;
	bool sync0Complete;

	// Number of chunks that were broadcasted over the network. This needs to be
	// set for every single buffer that is being broadcast, not for the entire
	// Assignment.
	atomic_int net_broadcast_chunk_count;

	// Flag that indicates the mbs is in test mode and we need
	// to copy tags into the Network RX tags after encrypt is
	// done.
	bool test_CopyTagsForNetRx;
} MeshBufferState_t;

typedef struct SendToAllBuffer {
	void * shadow;
	uint64_t totalBufSize;
	uint64_t numChunks;
	uint64_t chunkSize;
	uint64_t sendtoallmask;
	uint64_t bufferId;
} SendToAllBuffer_t;

// An array of all the send to
// all buffers to allocate
// in shared memory
typedef struct SendToAllBuffersArray {
	// Send to all buffers
	SendToAllBuffer_t sendToAllBuffersArray[MAX_SEND_TO_ALL_BUFFS];
	uint64_t arraySize;
} SendToAllBuffersArray_t;

typedef struct MeshCryptoKeyStateArray {
	// number of keys generated so far
	uint64_t key_count;
	uint64_t node_masks[MAX_NODE_MASKS];
	MeshCryptoKeyState_t keys[MAX_NODE_MASKS];
} MeshCryptoKeyStateArray_t;
/// CIO Mesh crypto state.
typedef struct MeshCryptoState {
	uint32_t numCryptoThreads;

	// The MBS assigned to the crypto thread -- this is the flag to
	// start crypto threads -- should be set last.
	atomic_uintptr_t assigned_mbs[MAX_CRYPTO_THREADS];

	// The BufferIdx of the MBS assigned to the crypto thread.
	atomic_int assigned_bufferIdx[MAX_CRYPTO_THREADS];

	// The number of assigned receive threads that the
	// reader thread is waiting for.
	atomic_int assigned_reading_count;
	// Pointer to array of flags indicating if the chunk this node is
	// responsible for has been encrypted. This will get updated
	// continuously for each chunk
	atomic_int * assigned_chunk_encrypted;
	// Pointer to where the assigned encrypt should write tags.
	atomic_uintptr_t assigned_encrypt_tag_ptr;

	// Pointer to the tag pointers for the chunks that are going out
	// on networking TX. If this is NULL, this means the chunk is not ready
	// to be sent.
	atomic_uintptr_t net_tx_tag_ptr[MAX_CHUNKS_PER_BLOCK];

	// Assigned MBS/bufferIndex/SyncCount to the networking threads.
	// the MBS is going to be the "flag" and needs to be set last.
	atomic_int assigned_bufferIdx_net;
	atomic_int assigned_syncCount_net;
	atomic_uintptr_t assigned_mbs_net;
} MeshCryptoState_t;

/// Crypto thread arguments to identify each thread.
typedef struct {
	void * mh;
	uint32_t whoami_local;
	uint32_t whoami_extended;
} CryptoArg_t;

/// Handle to the CIO Mesh.
typedef struct MeshHandle {
	// Handle to the mesh service.
	AppleCIOMeshServiceRef * service;

	// The extended node's id/rank.
	uint32_t myNodeId;
	// The leader's node id/rank.
	uint32_t leaderNodeId;
	// The number of nodes participating in the mesh which are directly
	// connected via CIO.
	uint32_t localNodeCount;

	// The number of nodes participating in the mesh.
	uint32_t extendedNodeCount;
	// The hardware will automatically divide a chunk into smaller sizes.
	// The division is based on the number of mesh links grouped up into a
	// mesh channel.
	uint32_t chunkDivider;

	// CIO performance statistics.
	MeshStats_t stats;

	// Buffer assignment to CIO Channel mappings for input/outputs.
	NodeAssignment_t * assignments;

	// Dispatch queue for CIO kernel notifications.
	dispatch_queue_t cioKernelQ;

	// Shared Crypto threads.
	pthread_t cryptoThreads[MAX_CRYPTO_THREADS];

	// Thread used for receiving blocks over the network in
	// extended ensembles only.
	pthread_t netReceiveThread;
	pthread_t netReceiveMultiPartitionThread;

	// Thread used for sending blocks over the network in
	// extended ensembled only.
	pthread_t netSendThread;
	pthread_t netSendMultiPartitionThread;

	// Crypto thread arguments.
	CryptoArg_t cryptoThreadArg[MAX_CRYPTO_THREADS];

	// Network crypto thread arguments.
	CryptoArg_t networkRxThreadArg;
	CryptoArg_t networkTxThreadArg;

	// CIOMesh debug verbosity level.
	uint32_t verbose_level;

	// If the reader thread is active.
	atomic_int reader_active;

	// If the reader thread is actually reading
	atomic_int reader_blocked;

	// Number of active threads running in the mesh API.
	atomic_int num_threads;

	// Crypto management.
	MeshCryptoState_t crypto;

	MeshCryptoKeyStateArray_t cryptoKeyArray;

	// Number of reads that need to be done.
	int64_t readRemaining;

	// The chainedBuffers to start reading on.
	atomic_uintptr_t startReadChainedBuffers;

	// The current activate chained buffers.
	atomic_uintptr_t activateChainedBuffers;

	// Semaphore to indicate the mesh has synchronized itself to begin data
	// transfers.
	dispatch_semaphore_t meshSynchronizeSem;

	// Signal used to indicate a MBS needs to be assigned.
	atomic_int pendingMBSAssignmentState;

	// The MBS that is about to be assigned.
	MeshBufferState_t * pendingMBSAssignBuffer;

	// Number of reads to assign that is pending.
	int64_t pendingMaxReadAssign;

	// Signal used to indicate the thread is ready to go.
	semaphore_t threadInitReadySignal;

	// Signal used to indicate the thread should go.
	semaphore_t threadInitGoSignal;

	// Signal used to indicate the thread is ready to go.
	// TODO(marco): this is probably not used. can remove it.
	semaphore_t threadSyncWaitSignal;

	// Signal used to indicate the leader should go (which will then let all
	// other threads know they have to go too). We are going to setup 2 of these
	// to ping-pong between them.
	semaphore_t threadLeaderGoSignal[THREAD_GO_SIGNAL_COUNT];

	// Signal used to indicate the thread should go.
	semaphore_t threadSyncGoSignal[kMaxCIOMeshNodes];

	// Signal used to indicate the network thread should go.
	// That network thread will receive blocks and decrypt them
	// into the user's buffer in the same thread.
	semaphore_t netReceivePeerGoSignal;

	// Signal to indicate the receiving network thread should go.
	// This is the network thread used during Broadcast & Gather (bag)
	// in a multi-parttion buffer.
	semaphore_t netReceiveMultiPartitionGoSignal;

	// Signal to indicate the network sender thread should go.
	// This is used by the network thread involved in Broadcast & Gather
	// in a multi-partition buffer.
	semaphore_t netSendMultiPartitionGoSignal;

	// Signal used to indicate the sender network thread should go.
	// This is used by the network thread involved in a p2p BaG.
	semaphore_t netSendPeerGoSignal;

	// Current idx to trigger on threadSyncGoSignal.
	uint8_t syncGoIdx;

	// For extended ensembles this can be 0, 1, 2 or 3
	uint8_t partitionIdx;

	// The connection information of peer nodes in an extended mesh
	PeerConnectionInfo * peerConnectionInfo;

	// Arena allocator for the shadow buffers
	MeshArena * shadow_arena;

	// The number of expected peer connections.
	// Used to determine if all expected connections have been established.
	// atomic_int peerConnectionCount;

	// Warmup the process before using CIOMesh once.
	bool warmupDone;

	// Array of send to all buffers
	SendToAllBuffersArray_t sendToAllBuffers;

	// The current active plan.
	// Contains an array of Execution plans and an index of the current one.
	MeshPlan_t activePlan;

#ifdef MESH_SKIP_LAST_GATHER_TIMESTAMP
	atomic_uint_fast64_t useThisTimestamp;
#endif
} MeshHandle_t;

typedef enum { CioHop = 10, NetworkHop = 100 } cost_t;
typedef struct MeshBufferSet MeshBufferSet_t;

__BEGIN_DECLS

// Private version that allows maxReads = 0 for infinite reading.
int MeshAssignBuffersToReaders_Private(MeshHandle_t * mh, MeshBufferState_t * mbs, int64_t maxReads);

// Private version that chunk size to be specified.
int MeshSetupBuffers_Private(MeshHandle_t * mh,
                             uint64_t bufferId,
                             uint64_t bufferSize,
                             uint64_t sectionSize,
                             uint64_t blockSize,
                             uint64_t chunkSize,
                             void ** bufferPtrs,
                             uint32_t numBuffers,
                             uint64_t nodeMask,
                             MeshBufferState_t ** ret_mbs);

int MeshSetupBuffersEx_Private(MeshHandle_t * mh, MeshBufferSet_t * bufferSets, uint16_t count);

// Copies the current node's chunk in the current section to all other sections.
// This is used to test code paths of larger ensembles on smaller ensembles.
// Clients should NEVER use this API.
// Returns the number of sections it has copied blocks into
int MeshCopyMyChunkToAllSections_private(MeshHandle * mh, MeshBufferState_t * mbs, uint8_t chunkIdx, char * tag);

// Sets up the mesh buffer to handle receiving from the same node
// for all partitions/sections.
void MeshSetupBufferForSelfCopy_private(MeshHandle_t * mh, MeshBufferState_t * mbs);

// Creates a mesh handle with a forced partition idx for testing.
MeshHandle_t * MeshCreateHandleWithPartition_private(uint32_t leaderNodeId, uint8_t partitionIdx);

__END_DECLS
