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

#include "AppleCIOMeshConfigUserClientInterface.h"
#include "Common/Config.h"
#include <stdint.h>

namespace AppleCIOMeshUserClientInterface
{
static const char * matchingName                 = "AppleCIOMeshService";
static const uint32_t AppleCIOMeshUserClientType = 0;

static const uint64_t PrepareFullBuffer = 0xFFFFFFFFFFFFFFFF;

typedef int64_t BufferId;
typedef uint8_t ForwardChainId;

static const BufferId kInvalidBufferId = -1;

class Method
{
  public:
	enum : uint32_t {
		NotificationRegister,
		NotificationUnregister,

		// Allocate a generic shared memory using ::SharedMemory
		AllocateSharedMemory,
		// Deallocate a shared memory ref
		DeallocateSharedMemory,
		// Assigns chunks within the shared memory to Mesh channels with a
		// I/O direction using ::AssignChunk.
		// Input chunks can only be assigned if the connecting node on the channel
		// has assigned a corresponding outgoing chunk. In the case the
		// other node has not assigned the outgoing chunk (yet), this will return
		// kIOReturnNotReady. The caller should retry in this case, or eventually
		// fail.
		// Outgoing assignments will always fail or succeed and should not be
		// retried because there is no checking on the connecting node.
		AssignSharedMemoryChunk,
		// Prints buffer assignment state.
		PrintBufferState,
		// Creates the forward chain for a set of buffers using ::ForwardChain.
		// The forwarder in the driver will prepare each chunk one after the other
		// and then loop back around from the last chunk to the first chunk.
		// In addition to chunks, the forward chain can span shared buffers.
		// This needs to be set after all assignments are completed, and has to be
		// set for buffers that specify it during creation.
		// The forward chain can be started and stopped using
		// Trap::StartForwarder and Trap::StopForwarder. When starting,
		// it will always start at StartBufferId::StartOffset and will go upto
		// element count or will be stopped at the next loop-around point.
		// ::ForwardChainId will be returned from this and should be used in
		// Trap::StartForwarder and Trap::StopForwarder
		SetupForwardChainBuffers,

		// set the maximum time (in nanoseconds) that the driver will wait
		// for a command to complete.
		SetMaxWaitTime,

		// Set the maximum time (in nanoseconds) that the driver will wait for
		// a batch of commands from a node.
		SetMaxWaitPerNodeBatch,

		// Starts a new "generation". A generation is a way to get all nodes in the
		// mesh on the same mesh usage. This can be used to synchronize between
		// processes or a barrier. Wait for MeshSynchronize notification which
		// will indicate the mesh has been synchronized. This method is simply
		// used to start synchronization.
		SynchronizeGeneration,

		OverrideRuntimePrepare,

		NumMethods
	};
};

class Trap
{
  public:
	enum : uint32_t {
		// Note: All below functions will work on the full assignment. The
		// expectation is to split up the buffer into smaller assignments if you
		// want granular control.

		// Blocking ready call. Takes BufferId and Offset. The entire assignment
		// for this offset will be ready.
		WaitSharedMemoryChunk,
		// Sends a pre-assigned outgoing shared memory assignment on assigned mesh
		// channels. Blocks until the assignment has been sent out. Takes BufferId
		// and Offset.
		SendAssignedData,
		// Prepares a chunk in the assigned shared memory for transfer. Takes
		// BufferId and Offset. Everything in this assignment will be prepared.
		PrepareChunk,
		// Prepares all chunks within the buffer. Takes a bufferID and direction.
		PrepareAllChunks,
		// Sends a chunk, and then prepares another buffer or chunk. Will block
		// until the chunk has been fully sent out. Takes a BufferID and
		// Offset for sending and preparing.
		// If the prepare offset is ::PrepareFullBuffer, the entire
		// buffer is prepared (if it is not the same as the sending buffer).
		SendAndPrepareChunk,
		// Sends all assigned chunks in the specified bufferId.  Used to
		// send to each chunk in the buffer to its assigned peer on its
		// own (as opposed to sending the same chunk to all peers)
		SendAllAssignedChunks,
		// Receives all input chunks in a buffer. Takes a BufferID.
		ReceiveAll,
		// Receives the next input chunk in a buffer. Takes a BufferID and a
		// pointer to a uint64 receivedOffset. This must be called multiple times
		// until all chunks have been received. The received chunk's
		// offset will be returned in receivedOffset. If chunks have been
		// returned, it will block until the next chunk in this buffer has
		// been received.
		ReceiveNext,
		// Receives a batch of input assignments in a buffer. Takes a BufferID,
		// a uint64 for the number of assignments to receive, a uint64 for the
		// number of nanoseconds to wait for, and 3 uint64 out pointers.
		// The first pointer will be filled with the number of chunks returned.
		// The second pointer will be filled in with all the different offsets.
		// This needs to be sized large enough to receive all the chunks desired.
		// The third pointer will be filled in with the tags of the different
		// offsets. This also needs to be sized to receive all the tags.
		ReceiveBatch,
		// Receives a batch of input assignments from a specific node in a buffer.
		// Takes a BufferId, a nodeId, a uint64 for the number of assignments to
		// receive, and 3 uint64 out pointers.
		// The first pointer will be filled with the number of chunks returned.
		// The second pointer will be filled in with all the different offsets.
		// This needs to be sized large enough to receive all the chunks desired.
		// The third pointer will be filled in with the tags of the different
		// offsets. This also needs to be sized to receive all the tags.
		ReceiveBatchForNode,

		// Stop any thread that may be spinning in the kernel
		InterruptWaitingThreads,
		// Allow new calls to i/o routines to proceed
		ClearInterruptState,
		// Stops any ongoing receive batches and returns from the trap immediately.
		InterruptReceiveBatch,

		// Starts a forward chain previously set. This will always start at
		// StartBufferId::StartOffset and continuously loop over all offsets
		// through all bufferIds. Takes a previously setup ForwardChainId and
		// the number of elements (uint32_t) to loop over the forward chain.
		// Only 1 forward chain can be started at a time. The forward chain
		// can be stopped early using Trap::StopForwardChain or it will naturally
		// stop after elementCount. ElementCount can be 0 to run indefinitely.
		StartForwardChain,
		// Stops an existing forward chain. This will stop at the next loop around
		// point.
		StopForwardChain,

        // Resets a buffer to an initialized/clear state. Takes a shared memory id.
        ResetBuffer,

		NumTraps
	};
};

enum class AccessMode : uint8_t {
	// Client will be notified of send completion or incoming data using
	// IncomingData and SendDataComplete notifications.
	Notification = 0x1,
	// Client will use Method::WaitSharedMemoryChunk to know when data has
	// arrived in a chunk or when data has been sent from a chunk.
	Block = 0x2,
};

enum class MeshDirection : uint8_t { In = 0x1, Out = 0x2 };

enum class Notification : uint32_t {
	// Incoming ::DataChunk
	IncomingData,
	// Sent ::DataChunk
	SendDataComplete,
	// Mesh Synchronized
	MeshSynchronized,
};

/// Generic Shared Memory definition.
struct SharedMemory {
	// Common shared memory buffer ID.
	BufferId bufferId;
	// Address of pre-allocated kernel/user shared memory.
	mach_vm_address_t address;
	// Size of the shared memory buffer. Buffer must be page aligned.
	int64_t size;
	// Size of each chunk/transfer size.
	int64_t chunkSize;
	// Stride the buffer so a chunk will be broken down into *strideSize*
	// elements with each element being *stride* apart.
	int64_t strideSkip;
	// The smaller granularity to break up a data chunk when striding data.
	int64_t strideWidth;
	// Whether this shared memory buffer is part of a forward chain. Buffers
	// not part of a forward chain will prepare commands after the incoming data
	// has been received, and would be more inefficient for repetitive
	// transfers.
	bool forwardChainRequired;
	// The breakdown of each chunk when forwarding. Each chunk will be broken
	// down as per this definition to give fine grained control on when forwarding
	// should start and how much data needs to be collected before the next
	// sub-chunk is collected.
	// The sum of this array must equal chunkSize / linksPerChannel.
	// LinksPerChannel can be found in MCUCI::HardwareState.
	// The +1 is because the kernel appends a trailer frame.  Do not use that
	// entry.
	int64_t forwardBreakdown[kMaxTBTCommandCount + 1];
} __attribute__((packed));

struct SharedMemoryRef {
	// Common shared memory buffer ID.
	BufferId bufferId;
	// Size of the shared memory buffer.
	int64_t size;
} __attribute__((packed));

/// The forward chain the forwarder will loop over.
struct ForwardChain {
	// The first buffer to start the forward chain from.
	BufferId startBufferId;
	// The first offset within each buffer to forward from. This must be
	// a multiple of SharedMemory.chunkSize.
	int64_t startOffset;
	// The last offset within each buffer that will be forwarded. Must be a
	// multiple of SharedMemory.chunkSize.
	int64_t endOffset;
	// The last buffer to do the forward chain through.
	BufferId endBufferId;
	// The offset within each section (if the buffer if split between
	// multiple partitions) to jump to during forwarding before moving
	// to the next buffer.
	// This indicates how to offset from endOffset_section0 to startOffset_section1
	int64_t sectionOffset;
	// The number of sections in the buffer.
	// If the buffer is not split between partitions, then there exists
	// a single section of the same size as each buffer.
	int64_t sectionCount;
} __attribute__((packed));

struct SetMaxWaitTime {
	// how many nanoseconds to wait for (0 == forever)
	uint64_t maxWaitTime;
} __attribute__((packed));

/// Data Chunk to transfer.
struct DataChunk {
	// Previously allocated shared memory buffer ID.
	BufferId bufferId;
	// Offset within the buffer to transfer. Has to be a multiple of
	// SharedMemory.chunkSize. In the case of strided buffers, has to be a
	// multiple of SharedMemory.strideSize.
	int64_t offset;
	// The size of the transfer. Has to be a multiple of SharedMemory.chunkSize.
	int64_t size;
} __attribute__((packed));

/// Shared memory definition with mesh channels assigned. It is undefined
/// behavior to assign the same chunks to multiple mesh channels.
struct AssignChunks {
	// Previously allocated shared memory buffer ID.
	BufferId bufferId;
	// Offset within the buffer to assign. Has to be a multiple of
	// SharedMemory.chunkSize.
	int64_t offset;
	// The size to assign. Has to be a multiple of SharedMemory.chunkSize.
	int64_t size;
	// The direction of the data chunk.
	// IODirectionIn for incoming chunks on the mesh channel.
	// IODirectionOut for outgoing chunks on the mesh channel.
	MeshDirection direction;
	// The mesh channel mask to assign the chunk to for incoming or outgoing chunks.
	// Incoming offsets should only be assigned to a single bit within the
	// mask. Outgoing can be assigned to multiple. For outgoing chunks only,
	// this mask is a node mask rather than a channel mask.
	int64_t meshChannelMask;
	// The access mode the client wil use to know when a chunk has been completed
	// either incoming or outgoing.
	AccessMode accessMode;
	// The node that this chunk is assigned to. For TX sourceNode, this should be
	// self or 0. For RX, this should be the receiving node. For forwarding, this
	// should be the originator node who is transmitting this chunk.
	AppleCIOMeshConfigUserClientInterface::NodeId sourceNode;
} __attribute__((packed));
}; // namespace AppleCIOMeshUserClientInterface
