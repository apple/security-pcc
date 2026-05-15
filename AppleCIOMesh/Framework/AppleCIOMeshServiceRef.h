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

#pragma once

@interface AppleCIOMeshServiceRef : NSObject

+ (NSArray<AppleCIOMeshServiceRef *> *)all;

// Dispatch queue that async updates will be delivered on
// (re-)register notification blocks after calling this.
- (void)setDispatchQueue:(dispatch_queue_t)queue;

// Block to be executed when data chunk has arrived.
typedef void (^IncomingDataChunkBlock)(uint64_t bufferId, uint64_t size, uint64_t offset);
- (BOOL)onIncomingDataChunk:(IncomingDataChunkBlock)block;

// Block to be executed when a send has been complete.
typedef void (^SendCompleteBlock)(uint64_t bufferId, uint64_t size, uint64_t offset);
- (BOOL)onSendComplete:(SendCompleteBlock)block;

// Block to be executed when mesh has been synchronized
typedef void (^MeshSynchronizedBlock)();
- (BOOL)onMeshSynchronized:(MeshSynchronizedBlock)block;

// Synchronizes all nodes in the mesh to a common generation.
- (BOOL)synchronizeMesh;

// Allocates a buffer in the shared Mesh view. This buffer
// will be used for sending and receiving data chunks
// out of. Breakdown has to be of size kMaxTBTCommandCount.
- (BOOL)allocateSharedMemory:(uint64_t)bufferId
                   atAddress:(mach_vm_address_t)bufferAddress
                      ofSize:(uint64_t)bufferSize
               withChunkSize:(uint64_t)chunkSize
              withStrideSkip:(uint64_t)strideSkip
             withStrideWidth:(uint64_t)strideWidth
        withCommandBreakdown:(int64_t *)breakdown;

// Deallocate the bufferId in the shared Mesh view.
- (BOOL)deallocateSharedMemory:(uint64_t)bufferId ofSize:(uint64_t)bufferSize;

// Assigns part of an allocated shared memory to incoming
// data from the specified mesh channel.
// Offset and size must be a multiple of chunkSize allocated.
- (BOOL)assignSharedMemory:(uint64_t)bufferId
                  atOffset:(uint64_t)offset
                    ofSize:(uint64_t)size
     toIncomingMeshChannel:(uint64_t)channel
            withAccessMode:(uint8_t)mode
                  fromNode:(uint32_t)node;

// Assigns part of an allocated shared memory to outgoing
// data on all mesh channels.
// Offset and size must be a multiple of chunkSize allocated.
- (BOOL)assignSharedMemory:(uint64_t)bufferId
                  atOffset:(uint64_t)offset
                    ofSize:(uint64_t)size
    toOutgoingMeshChannels:(uint64_t)channelMask
            withAccessMode:(uint8_t)mode
                  fromNode:(uint32_t)node;

// Sets a forward chain. This has to be done after all assignments
// are created so the forwarder can automatically prepare the next
// buffer in the chain.  This call starts the forwarder
- (BOOL)setupForwardChainWithId:(uint8_t *)chainId
                           from:(uint64_t)startBufferId
                             to:(uint64_t)endBufferId
                    startOffset:(uint64_t)startOffset
                      endOffset:(uint64_t)endOffset
              withSectionOffset:(uint64_t)sectionOffset
                   sectionCount:(uint64_t)sectionCount;

// Start the forward chain if it hasn't already been started
- (BOOL)startForwardChain:(uint8_t)chainId forIteration:(uint32_t)iterations;

// Set the max amount of time, in nanoseconds, that we will wait for a command
// Zero means wait forever.
- (BOOL)setMaxWaitTime:(uint64_t)maxWaitNanos;

// Stop a forward chain that has been started. The chain will be
// complete before it stops.
- (BOOL)stopForwardChain;

// Set runtime prepare to false
- (BOOL)overrideRuntimePrepareFor:(uint64_t)bufferId;

// Prepares a data chunk for transfer.
- (BOOL)prepareDataChunkTransferFor:(uint64_t)bufferId atOffset:(uint64_t)offset;

// Prepares all incoming data chunk transfers.
- (BOOL)prepareAllIncomingTransferFor:(uint64_t)bufferId;

// Prepares all outgoing data chunk transfers.
- (BOOL)prepareAllOutgoingTransferFor:(uint64_t)bufferId;

// Blocking call to get notified when it is safe to read or
// continue writing into a data chunk of the shared memory
// at the specified offset.  The tag is a pointer to a kTagSize
// array of bytes that will hold the received aes-gcm tag.
- (BOOL)waitOnSharedMemory:(uint64_t)bufferId atOffset:(uint64_t)offset withTag:(char *)tag;

// Blocking call to get notified when all incoming shared
// memory chunks of the buffer have been received.
- (BOOL)waitOnAllIncomingChunksOf:(uint64_t)bufferId;

// Blocking call to get notified when the next incoming shared
// memory chunk of the buffer has been received.  The tag is a
// a pointer to a kTagSize array that will get the aes-gcm tag
// that was sent with the data.
- (BOOL)waitOnNextIncomingChunkOf:(uint64_t)bufferId withOffset:(uint64_t *)receivedOffset withTag:(char *)tag;

// Blocking call to get notified when the next batch of incoming
// shared memory chunks of the buffer has been received. The offsets
// and tags received must be large enough for the batch size specified
// or big enough to recive everything if batch size is 0.
- (BOOL)waitOnNextBatchIncomingChunkOf:(uint64_t)bufferId
                         withBatchSize:(uint64_t)batch
                           withTimeout:(uint64_t)timeoutMicroseconds
                     withReceivedCount:(uint64_t *)receivedCount
                   withReceivedOffsets:(uint64_t *)receivedOffsets
                      withReceivedTags:(char *)receivedTags;

// Blocking call to get notified when the next bath of incoming shared memory
// chunks of the buffer from a node has been received. The offsets
// and tags received must be large enough for the batch size specified
// or big enough to recive everything if batch size is 0.
- (BOOL)waitOnNextBatchIncomingChunkOf:(uint64_t)bufferId
                              fromNode:(uint32_t)nodeId
                         withBatchSize:(uint64_t)batch
                     withReceivedCount:(uint64_t *)receivedCount
                   withReceivedOffsets:(uint64_t *)receivedOffsets
                      withReceivedTags:(char *)receivedTags;

// Sends all assigned outgoing data chunks on a shared buffer at a particular
// offset.  The tag is a pointer to a kTagSize array of bytes that contains
// the aes-gcm tag for the chunk being sent.
- (BOOL)sendAssignedDataChunkFrom:(uint64_t)bufferId atOffset:(uint64_t)offset withTags:(char *)tags;

// Sends all assigned chunks in the entire buffer.  Will send in parallel on
// multiple links.  The tags pointer is an array of kTagSize entries that have
// the aes-gcm tag for each chunk that will be sent
- (BOOL)sendAllAssignedDataFrom:(uint64_t)bufferId withTags:(char *)tags;

// Sends a previously assigned data chunk and then immediately prepares another data
// chunk for transfer.  The tag is a pointer to a kTagSize array of bytes that
// contains the aes-gcm tag for the chunk being sent.
- (BOOL)sendAssignedDataChunkFrom:(uint64_t)sendBufferId
                           atOffset:(uint64_t)sendOffset
                           withTags:(char *)tags
    andPrepareAssignedDataChunkFrom:(uint64_t)prepareBufferId
                           atOffset:(uint64_t)prepareOffset;

// Interrupts all waiting (waitOnSharedMemory) threads.
- (BOOL)interruptWaitingThreads:(uint64_t)bufferId;

// Resets interrupt state.
- (BOOL)clearInterruptState:(uint64_t)bufferId;

// Immediately return whatever has been collected by the
// receive batch.
- (BOOL)interruptPendingReceiveBatch;

// Prints buffer assignment state.
- (BOOL)printAssignmentStateFor:(uint64_t)bufferId;

// Resets a buffer to an initialized state.
- (BOOL)resetBuffer:(uint64_t)bufferId;

@end
