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

#include "Util/SymbolWorkaround.h"

#include <libkern/c++/OSBoundedArray.h>
#include <libkern/c++/OSBoundedArrayRef.h>
#include <libkern/c++/OSObject.h>

#include "AppleCIOMeshUserClientInterface.h"
#include "Common/Config.h"

namespace MUCI  = AppleCIOMeshUserClientInterface;
namespace MCUCI = AppleCIOMeshConfigUserClientInterface;

class AppleCIOMeshLink;
class AppleCIOMeshReceiveCommand;
class AppleCIOMeshService;
class AppleCIOMeshSharedMemory;
class AppleCIOMeshThunderboltCommands;
class AppleCIOMeshTransmitCommand;
class IOThunderboltTransmitCommand;
struct AppleCIOMeshAssignmentMap;

class AppleCIOMeshPreparedCommand final : public OSObject
{
	OSDeclareDefaultStructors(AppleCIOMeshPreparedCommand);
	using super = OSObject;

  public:
	static AppleCIOMeshPreparedCommand * allocate(AppleCIOMeshSharedMemory * provider,
	                                              MUCI::BufferId bufferId,
	                                              uint64_t offset,
	                                              AppleCIOMeshThunderboltCommands * commandsProvider);
	bool initialize(AppleCIOMeshSharedMemory * provider,
	                MUCI::BufferId bufferId,
	                uint64_t offset,
	                AppleCIOMeshThunderboltCommands * commandsProvider);
	virtual void free() APPLE_KEXT_OVERRIDE;
	uint64_t getOffset();
	MCUCI::NodeId getSourceNode();
	bool isSourceNodeSet();

	void setSourceNode(MCUCI::NodeId node);
	void setupCommand(AppleCIOMeshLink * link, AppleCIOMeshTransmitCommand * command);
	void holdCommands();
	void prepareCommands(bool wholeBuffer);
	// Returns true when done all these prepared commands.
	bool dripPrepare(int64_t * linkIdx);
	void dispatch(bool reverse, char * tag, size_t tagSz);
	bool prepared();
	void setWholeBufferPrepared(bool wholeBuffer);

  private:
	AppleCIOMeshSharedMemory * _provider;
	MUCI::BufferId _bufferId;

	uint64_t _offset;
	MCUCI::NodeId _sourceNode;
	bool _sourceNodeSet;

	AppleCIOMeshThunderboltCommands * _commandsProvider;

	AppleCIOMeshTransmitCommand * _commands[kMaxMeshLinkCount];
	OSBoundedArrayRef<IOThunderboltTransmitCommand *> _tbtCommands[kMaxMeshLinkCount];
	AppleCIOMeshLink * _commandMeshLinks[kMaxMeshLinkCount];
	uint8_t _commandCount;

	bool _wholeBufferPrepared;
	uint8_t _tbtCommandsLength;

	_Atomic(bool) _holdingForPrepare;
	uint32_t _pendingSendMask;
	bool _preparedForUCSend;

	uint32_t _dripPrepareLinkMask;
};

const int kMaxAssignmentChunks = 10;

class AppleCIOMeshAssignment final : public OSObject
{
	OSDeclareDefaultStructors(AppleCIOMeshAssignment);
	using super = OSObject;

  public:
	static AppleCIOMeshAssignment * allocate(AppleCIOMeshSharedMemory * provider, MUCI::MeshDirection direction);
	bool initialize(AppleCIOMeshSharedMemory * provider, MUCI::MeshDirection direction);
	virtual void free() APPLE_KEXT_OVERRIDE;

	void setRXAssignedNode(MCUCI::NodeId node);

	MUCI::MeshDirection getDirection();
	AppleCIOMeshSharedMemory * getProvider();

	void getCurrentTag(char * tag, size_t tagSz);
	size_t getAssignmentSizePerLink();

	void addOffset(int64_t offset, AppleCIOMeshPreparedCommand * preparedCommand);
	void addLastOffset(int64_t offset, uint8_t linkChannelIdx, AppleCIOMeshPreparedCommand * preparedCommand);
	void addFirstOffset(int64_t offset, uint8_t linkChannelIdx, AppleCIOMeshPreparedCommand * preparedCommand);
	void hold();
	void prepare(uint8_t linkMask);
	void markForwardIncomplete();
	// Returns true if the full assignment has been prepared.
	bool dripPrepare(int64_t * offsetIdx, int64_t * linkIdx);
	void submit(uint8_t linkChannelMask, char * tag, size_t tagSz);
	void setWholeBufferPrepared(bool wholeBuffer);

	/**
	 Checks if the full assignment has been prepared.
	 */
	bool checkPrepared();

	/**
	 If the assignment is not ready, checkReady will also ask the NHI
	 ring to check if the TBT Command has completed.
	 */
	bool checkReady();

	/**
	 Optimized version of checkReady() for TX only.
	 */
	bool checkTXReady(uint8_t linkChannelMask);

	/**
	 Returns the trailer that was received. Will return FALSE if the data has
	 not been received yet.
	 */
	bool getTrailer(uint8_t linkChannelIdx, char * tag, size_t tagSz);

	/**
	 Unlike checkReady, this will not ask the NHI ring to check if the TBT
	 command has completed.
	 */
	bool isReady();

	/**
	 Checks if the assignment has been forwarded fully.
	 */
	bool checkForwardComplete();

	/**
	 If the assignment has been fully dispatched.
	 */
	bool isDispatched(uint8_t linkChannelMask);

	void printState();
	void dumpReadyState(void);

	int64_t
	tmp()
	{
		return _offsets[0];
	}

	int64_t tmp2();

	int
	getAssignedNode()
	{
		return _assignedRXNode;
	}

  private:
	// If this is an input assignment, the source node the data is coming from.
	MCUCI::NodeId _assignedRXNode;

	AppleCIOMeshSharedMemory * _provider;
	MUCI::MeshDirection _direction;
	// only set for Tx commands (i.e. an "out" direction assignment)
	AppleCIOMeshPreparedCommand * _preparedCommands[kMaxAssignmentChunks];
	// Offsets here is an array of every single chunk in this assignment
	int64_t _offsets[kMaxAssignmentChunks];
	uint32_t _offsetIdx;

	// These offsets, are the offsets for each link in a channel.
	// IE: if we have assigned 0 1 | 2 3, 0/2 are first offsets
	// 1/3 are last offsets. MeshService will split up an assignment
	// into the number of links per channel and the first/last are
	// the offsets in each of those subsections.
	int64_t _lastOffsets[kMaxMeshLinksPerChannel];
	AppleCIOMeshPreparedCommand * _preparedLastCommands[kMaxMeshLinksPerChannel];
	int64_t _firstOffsets[kMaxMeshLinksPerChannel];
	AppleCIOMeshPreparedCommand * _preparedFirstCommands[kMaxMeshLinksPerChannel];

	uint8_t _linksPerChannel;

	OSBoundedArray<bool, kMaxMeshLinksPerChannel> _ready;
};

typedef struct NodeAssignmentMap {
	AppleCIOMeshAssignmentMap * provider;
	MCUCI::NodeId node;
	// All the indices in the assignment map assigned to this node.
	uint8_t assignedIdx[kMaxAssignmentCount];
	// Number of assignments
	uint8_t assignCount;
	// The assigned indices for a link that is going/coming from that node.
	uint8_t linkAssignedIdx[kMaxMeshLinksPerChannel][kMaxAssignmentCount];
	// Number of assigned assignments to a link going/coming from that node.
	uint8_t linkAssignCount[kMaxMeshLinksPerChannel];
	// The current index that needs to be prepared for transfer.
	// This is an index to assignedIdx. This is also per link.
	_Atomic(uint8_t) linkCurrentIdx[kMaxMeshLinksPerChannel];
	// How much we have prepared for this node so we can stop early.
	_Atomic(uint64_t) totalPrepared[kMaxMeshLinksPerChannel];
} NodeAssignmentMap;

typedef struct AppleCIOMeshAssignmentMap {
	// The map will have LINKx the number of assignments in here so that we can
	// check each link's assignment individually.

	friend class AppleCIOMeshSharedMemory;

  protected:
	// The offset of the assignment to use --> do not use this directly.
	int64_t assignmentOffset[kMaxAssignmentCount];

  public:
	// The node assigned for each assignment offset.
	int64_t assignedNode[kMaxAssignmentCount];
	// The tag for each assignment
	char assignmentTag[kMaxAssignmentCount][kTagSize];
	// If the assignment is ready.
	bool assignmentReady[kMaxAssignmentCount];
	// If the assignment ready has been handled.
	bool assignmentNotified[kMaxAssignmentCount];
	// Node assignments
	NodeAssignmentMap nodeMap[kMaxCIOMeshNodes];

	// The link for the assignment within the map.
	uint8_t linkIdx[kMaxAssignmentCount];

	uint8_t assignmentCount;
	uint8_t linksPerChannel;
	_Atomic(uint8_t) remainingAssignments;
	_Atomic(bool) allReceiveFinished;

	// The index to start receive interrupt checking in. We want to check
	// the forward offset first so we can forward the data quickly.
	uint8_t startingIdx;
	bool startingIdxSet;

	MUCI::MeshDirection direction;
	AppleCIOMeshSharedMemory * sharedMemory;

	bool checkPrepared();
	void addAssignmentForNode(MCUCI::NodeId node, uint8_t idx);
	void addLinkAssignmentForNode(MCUCI::NodeId node, uint8_t idx, uint8_t link);
	bool checkAllReady(bool * interrupted);
	bool checkReady(uint32_t idx, bool * interrupted);
	uint8_t getIdxForOffset(int64_t offset);
	int64_t getAssignmentOffset(uint32_t idx);
	void hold();
	void reset();
	void dump();
} AppleCIOMeshAssignmentMap;
