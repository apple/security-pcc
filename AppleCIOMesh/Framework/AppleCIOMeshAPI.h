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

#pragma once

#include <stddef.h>
#include <stdint.h>
#include <sys/cdefs.h>

__BEGIN_DECLS

//
// The current Mesh api version number.  This gets
// bumped when there are additions or changes that
// are not compatible.
//
#define MESHAPI_VERSION 223

typedef struct MeshHandle MeshHandle_t;

//
// Mesh Buffers are used for broadcast and gather only.
// Scatter all and send all are not MeshBuffers.
//
typedef struct MeshBufferState MeshBufferState_t;

//
// A map filled with the cost of data
// transfer from one node to another.
//
typedef struct MeshEnsembleMap {
	uint32_t node_count;
	// 1D array representing a 2D array
	// adjacency matrix with node_count
	// rows and columns. Each element should
	// be accessed like this:
	// route_cost[node_i * node_count + node_j]
	uint32_t * route_cost;
} MeshEnsembleMap_t;

typedef struct MeshBufferSet {
	uint64_t bufferId;
	uint64_t bufferSize;
	uint64_t blockSize;
	uint64_t chunkSize;
	void ** bufferPtrs;
	uint32_t numBuffers;
	uint64_t nodeMask;
	uint64_t sectionSize;
	MeshBufferState_t * mbs;
} MeshBufferSet_t;

// Describes the number of syncs for a given buffer set.
// Used as an array in MeshAssignBuffersToReadersBulk to describe
// which MeshBufferState will run after which and for how many times.
typedef struct MeshExecPlan {
	MeshBufferState_t * mbs;
	uint64_t maxReads;
} MeshExecPlan_t;

//
// Creates and returns the ensemble map based
// on the number of nodes in the ensemble. The
// caller is responsible for calling
// MeshFreeEnsembleMap to free the returned
// map.
//
MeshEnsembleMap_t * MeshGetEnsembleMap(uint32_t nodeCount);

//
// Frees the ensemble map.
//
void MeshFreeEnsembleMap(MeshEnsembleMap_t *);

//
// Helper function to return the cost to transfer data between
// a source and destination node by indexing into the provided
// ensemble map.
//
uint32_t MeshGetRouteCostForNodeRank(MeshEnsembleMap_t * map, uint32_t srcNode, uint32_t dstNode);

// MARK: - Mesh Configuration

//
// Get this node's id (aka "rank") and the total number
// of nodes in the mesh.
//
// You can call this before creating the mesh
//
bool MeshGetInfo(uint32_t * myNodeId, uint32_t * numNodesTotal);

//
// Adjust mesh logging for debug purposes.  Values above 5
// are _very_ noisy.
//
void MeshSetVerbosity(MeshHandle_t * mh, uint32_t level);

// MARK: - Mesh Handle Configuration

// Create a MeshHandle_t to interact with the mesh.  The leaderNodeId
// should be zero.
MeshHandle_t * MeshCreateHandle(uint32_t leaderNodeId);

// Releases allocated resources, shutsdown network connections, threads, etc.
void MeshDestroyHandle(MeshHandle_t * mh);

//
// Set the crypto key to use for encrypting mesh communication.
//
// TODO: This needs to move to _Private.
//
void MeshSetCryptoKey(const void * key, size_t keysz);

//
// Set the maximum time in nanoseconds to wait for data when
// calling MeshBroadcastAndGather().  A value of zero means
// wait forever.
//
void MeshSetMaxTimeout(MeshHandle_t * mh, uint64_t maxWaitNanos);

//
// Call this to initiate the reader threads before the first
// call to MeshBroadcastAndGather()
//
void MeshStartReaders(MeshHandle_t * mh);

//
// Call this to stop any reader threads and to reset internal state
// on the MeshBufferState_t.  This should only be done when you are
// finished calling MeshBroadcastAndGather().
//
bool MeshStopReaders(MeshHandle_t * mh);

//
// Claims exclusive access to the mesh. This has to be done before
// starting readers, broadcast and gather, scatter/send all, or barrier.
// It is allowed to allocate buffers before claiming mesh exclusivity.
// Returns POSIX error codes.
//
int MeshClaim(MeshHandle_t * mh);

//
// Releases previously held exclusive claims on the mesh. All buffers
// have to be freed before release.
//
void MeshReleaseClaim(MeshHandle_t * mh);

// MARK: - Broadcast and Gather
// MARK: Buffer Management

//
// Provides an allocation hint to CIOMesh to pre-allocate and page fault
// its internal memory to avoid paying the cost later.
// This function should be called outside the hot path.
int MeshSetupBuffersHint(MeshHandle_t * mh, uint64_t bufferSize);

//
// Setup an array of buffers for use with the mesh.  Each buffer
// in the bufferPtrs array should be bufferSize bytes long.  The
// buffers are further subdivided into blocks of blockSize bytes
// (blockSize must evenly divide bufferSize and be equal to the
// number of nodes in the system).  The chunkSize should evenly
// divide the blockSize and is used for sending smaller parts of
// the block to allow encryption to work in a pipelined fashion.
// It is ok if chunkSize == blockSize but for larger block sizes
// this is defintely less than ideal.
//
// Each node is responsible for the data at offset blockSize*nodeRank
// in the buffer.  Each node in the mesh should only modify the
// contents of that region in the buffer.
//
int MeshSetupBuffers(MeshHandle_t * mh,
                     uint64_t bufferId,
                     uint64_t bufferSize,
                     uint64_t blockSize, /* ignored */
                     uint64_t chunkSize, /* ignored */
                     void ** bufferPtrs,
                     uint32_t numBuffers,
                     MeshBufferState_t ** ret_mbs);

// Setup multiple sets of buffers. Each set contains an array of buffers for use with the mesh.
//
// Each buffer in the bufferPtrs array should be bufferSize bytes long.
// The buffers are further subdivided into blocks of blockSize bytes
// (blockSize must evenly divide bufferSize and be equal to the
// number of nodes in the system).  The chunkSize should evenly
// divide the blockSize and is used for sending smaller parts of
// the block to allow encryption to work in a pipelined fashion.
// It is ok if chunkSize == blockSize but for larger block sizes
// this is defintely less than ideal.
//
// Each node is responsible for the data at offset blockSize*nodeRank
// in the buffer.  Each node in the mesh should only modify the
// contents of that region in the buffer.
//

int MeshSetupBufferEx(MeshHandle_t * mh, MeshBufferSet_t * bufferSets, uint16_t count);

//
// Release the kernel side resources associated with the buffers
// in the MeshBufferState_t.
//
int MeshReleaseBuffers(MeshHandle_t * mh, MeshBufferState_t * mbs);

//
// Clears the mesh buffers for a new request. This function is not thread safe
// with MeshAssignBuffersToReaders. The caller is expected to not assign buffers
// while calling clear buffers.
//
int MeshClearBuffers(MeshHandle_t * mh, MeshBufferState_t * mbs);

// MARK: Data Flow

//
// Set the max number of times you expect to call MeshBroadcastAndGather()
// for a given buffer.  This value can be greater than the number of
// buffer pointers specified in MeshSetupBuffers() and if it is, the
// mesh api will iterate through the buffers multiple times.
//
// Note: The readers have to started with MeshStartReaders before this is
// called.
//
int MeshAssignBuffersToReaders(MeshHandle_t * mh, MeshBufferState_t * mbs, int64_t maxReads);

// Specifies the sequence in which MeshBroadcastAndGather will be called each MeshBufferState_t.
// This allows the mesh to prepare the next MeshBufferState_t while the current one is being transferred.
int MeshAssignBuffersToReadersBulk(MeshHandle_t * mh, MeshExecPlan_t * plan, size_t planCount);

//
// Broadcast the data from this node to all other nodes in the
// mesh and gather all the data from the other nodes in the mesh.
// This operates on the current buffer in the array of buffer
// pointers.
//
// Note: before calling this function the data for this node's
// region of the current buffer should be ready.  The data for
// other nodes may have already arrived so do not modify other
// regions of the buffer.  After this call returns you can do
// what you want with the contents of the entire buffer until
// the next call to MeshBroadcastAndGather() will operate on this
// buffer again (e.g. if you called MeshSetupBuffers() with an
// array of 16 buffers, after the call to MeshBroadcastAndGather()
// returns, you can call it 15 more times before this same buffer
// becomes active again).
//
int MeshBroadcastAndGather(MeshHandle_t * mh, MeshBufferState_t * mbs);

// MARK: - Scatter and Send All
// MARK: Buffer Management

//
// A send-to-all buffer is a single buffer which the leader node
// will broadcast to all the other nodes in the mesh.  All nodes
// in the mesh should call this.
//
int MeshSetupSendToAllBuffer(MeshHandle_t * mh, const uint64_t sendToAllBufferId, void * sendToAllBuf, uint64_t sendToAllBufSize);

//
// A send-to-all buffer is a single buffer which the leader node
// will broadcast to all the other nodes in the mesh that are specified in the nodeMask.
// All nodes in the mesh should call this.
//
int MeshSetupSendToAllBufferEx(
    MeshHandle_t * mh, const uint64_t nodeMask, const uint64_t sendToAllBufferId, void * sendToAllBuf, uint64_t sendToAllBufSize);

//
// A scatter-to-all buffer is a buffer with unique contents for
// each node.  The buffer is divided into blocks that are each
// scatterToAllBufSize/nodeCount bytes long.  Each node receives
// data offset nodeRank * (scatterToAllBufSize/nodeCount).  The
// leader node data is not actually sent.
//
// All nodes should call this.
//
int MeshSetupScatterToAllBuffer(MeshHandle_t * mh, uint64_t scatterBufferId, void * scatterBuf, uint64_t scatterBufSize);

//
// Use this to release a specific buffer allocated with
// MeshSetupSendToAllBuffer() or MeshSetupScatterToAllBuffer().
// DO NOT use this on a buffer create with MeshSetupBuffers()
//
int MeshReleaseBuffer(MeshHandle_t * mh, uint64_t bufferId, uint64_t bufferSize);

// MARK: Data Flow

//
// Used by a leader node to send the buffer to all the other nodes
// in the mesh.  Follower nodes should not call this.
//
bool MeshSendToAllPeers(MeshHandle_t * mh, const uint64_t sendToAllBufferId, void * sendToAllBuf, uint64_t sendToAllBufSize);

//
// Send each node its portion of the scatter-to-all buffer.
// Only the leader node should call this.  For this function
// the scatterBufSize should be the size of the entire buffer.
//
bool MeshScatterToAll(MeshHandle_t * mh, uint64_t bufferId, void * scatterBuf, uint64_t scatterBufSize);

//
// Used by follower nodes to receive either a send-to-all or
// scatter-to-all buffer from the leader node.
// The leader node is the 0th rank node. To receive from a
// different leader node (for example within a mask) use
// MeshReceiveFromLeaderEx function instead.
//
// Note: the bufSize argument should be the size of the portion
// of the buffer that this node is receiving (not the size of
// the entire buffer)
//
int MeshReceiveFromLeader(MeshHandle_t * mh, uint64_t bufferId, void * bufPtr, uint64_t bufSize, uint64_t offset);

//
// Used by follower nodes to receive either a send-to-all or
// scatter-to-all buffer from a given leader node.
//
// Note: the bufSize argument should be the size of the portion
// of the buffer that this node is receiving (not the size of
// the entire buffer)
//
int MeshReceiveFromLeaderEx(
    MeshHandle_t * mh, uint32_t leaderNodeId, uint64_t bufferId, void * bufPtr, uint64_t bufSize, uint64_t offset);

// MARK: - Barrier

//
// A simple barrier.  After this function returns successfully,
// all nodes will have reached the call to MeshBarrier().  This
// is useful to synchronize nodes before entering the main loop
// of computation. The mesh has to be claimed before using a
// barrier. This may lock indefinitely if the mesh has not been
// claimed.
//
int MeshBarrier(MeshHandle_t * mh);

//
// Get the offset in the distributed buffer that corresponds to a given node.
// Usually the first node will have the first equal slice of the buffer, and the second will follow etc, however, when a
// node mask is involved, for example involving nodes 2 and 3, then the first slice will belong to node 2 and the second
// slice will belong to node 3. This API provides a helper to calculate those offsets in a BufferState that involves a
// mask.
// The particular mask is the one assigned to the provided MeshBufferState when it was setup in MeshSetupBufferEx.
//
// Note: providing a nodeId for a node that is _not_ part of the mask is a logical error and the results are
// unpredictable.
//
uint64_t MeshGetBufferOffsetForNode(MeshHandle_t * mh, MeshBufferState_t * mbs, uint32_t nodeId);

// Logs the stats for all the recent syncs up to numSyncs.
// The maximum value allowed for numSyncs is 3K
void MeshLogStats(MeshHandle_t * mh, uint64_t numSyncs);

__END_DECLS
