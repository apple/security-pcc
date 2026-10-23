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

#include "AppleCIOMeshSharedMemoryHelpers.h"
#include "AppleCIOMeshLink.h"
#include "AppleCIOMeshService.h"
#include "AppleCIOMeshSharedMemory.h"
#include "AppleCIOMeshThunderboltCommands.h"
#include "AppleCIOMeshUserClient.h"

#define LOG_PREFIX "AppleCIOMeshSharedMemoryHelper"
#include "Common/Align.h"
#include "Common/Compiler.h"
#include "Signpost.h"
#include "Util/Error.h"
#include "Util/Log.h"

OSDefineMetaClassAndStructors(AppleCIOMeshPreparedCommand, OSObject);
OSDefineMetaClassAndStructors(AppleCIOMeshAssignment, OSObject);

// MARK: - PreparedCommand Helper class

AppleCIOMeshPreparedCommand *
AppleCIOMeshPreparedCommand::allocate(AppleCIOMeshSharedMemory * provider,
                                      MUCI::BufferId bufferId,
                                      uint64_t offset,
                                      AppleCIOMeshThunderboltCommands * commandsProvider)
{
	auto preparedCommand = OSTypeAlloc(AppleCIOMeshPreparedCommand);
	if (preparedCommand != nullptr && !preparedCommand->initialize(provider, bufferId, offset, commandsProvider)) {
		OSSafeReleaseNULL(preparedCommand);
	}
	return preparedCommand;
}

bool
AppleCIOMeshPreparedCommand::initialize(AppleCIOMeshSharedMemory * provider,
                                        MUCI::BufferId bufferId,
                                        uint64_t offset,
                                        AppleCIOMeshThunderboltCommands * commandsProvider)
{
	_provider          = provider;
	_bufferId          = bufferId;
	_offset            = offset;
	_commandsProvider  = commandsProvider;
	_preparedForUCSend = false;
	_pendingSendMask   = 0;
	_sourceNodeSet     = false;
	_commandCount      = 0;
	atomic_store(&_holdingForPrepare, false);

	return true;
}

void
AppleCIOMeshPreparedCommand::free()
{
	super::free();
}

uint64_t
AppleCIOMeshPreparedCommand::getOffset()
{
	return _offset;
}

MCUCI::NodeId
AppleCIOMeshPreparedCommand::getSourceNode()
{
	return _sourceNode;
}

bool
AppleCIOMeshPreparedCommand::isSourceNodeSet()
{
	return _sourceNodeSet;
}

void
AppleCIOMeshPreparedCommand::setSourceNode(MCUCI::NodeId node)
{
	_sourceNode    = node;
	_sourceNodeSet = true;
}

void
AppleCIOMeshPreparedCommand::setupCommand(AppleCIOMeshLink * link, AppleCIOMeshTransmitCommand * command)
{
	assertf(command->getDataChunk().offset == _offset, "Assigning command with offset %lld to preparedCommand with offset %lld",
	        command->getDataChunk().offset, _offset);
	assertf(command->getProvider() == _commandsProvider, "Assigning command with a different expected command provider");

	_commands[_commandCount]         = command;
	_tbtCommands[_commandCount]      = command->getCommands();
	_commandMeshLinks[_commandCount] = link;
	_commandCount++;

	_tbtCommandsLength = (uint8_t)command->getCommandsLength();
}

void
AppleCIOMeshPreparedCommand::holdCommands()
{
	assertf(!_commandsProvider->isTxForwarding(), "HoldCommands should be only be called for non-forwarding commands");
	atomic_store(&_holdingForPrepare, true);
	_commandsProvider->markTxUnready();
}

void
AppleCIOMeshPreparedCommand::prepareCommands(bool wholeBuffer)
{
	assertf(!_commandsProvider->isTxForwarding(), "PrepareCommands should be only be called for non-forwarding commands");

	// count number of links, set the last command's waiting count
	uint32_t linkMask = 0x0;

	for (uint8_t i = 0; i < _commandCount; i++) {
		linkMask |= (0x1 << (_commandMeshLinks[i]->getRID()));

		for (uint8_t j = 0; j < _tbtCommandsLength; j++) {
			_commandMeshLinks[i]->prepareTXCommand(_sourceNode, _tbtCommands[i][j]);
		}

		_pendingSendMask |= (0x1 << i);
	}

	TX_CHUNK_PREPARED_TR(_provider->getId(), getOffset(), _pendingSendMask);

	_provider->addPrepared(_commandCount);

	_commandsProvider->setOutgoingCommandCountAndMask(_commandCount, linkMask);
	_preparedForUCSend = true;
	atomic_store(&_holdingForPrepare, false);
	_wholeBufferPrepared = wholeBuffer;
}

bool
AppleCIOMeshPreparedCommand::dripPrepare(int64_t * linkIdx)
{
	assertf(!_commandsProvider->isTxForwarding(), "PrepareCommands should be only be called for non-forwarding commands");

	_dripPrepareLinkMask |= (0x1 << (_commandMeshLinks[*linkIdx]->getRID()));
	for (uint8_t j = 0; j < _tbtCommandsLength; j++) {
		_commandMeshLinks[*linkIdx]->prepareTXCommand(_sourceNode, _tbtCommands[*linkIdx][j]);
	}
	_provider->addPrepared(1);

	_pendingSendMask |= (0x1 << *linkIdx);
	*linkIdx = (*linkIdx) + 1;

	if (*linkIdx == _commandCount) {
		_commandsProvider->setOutgoingCommandCountAndMask(_commandCount, _dripPrepareLinkMask);
		_preparedForUCSend = true;
		atomic_store(&_holdingForPrepare, false);
		_wholeBufferPrepared = true;

		_dripPrepareLinkMask = 0x0;

		TX_CHUNK_PREPARED_TR(_provider->getId(), getOffset(), _pendingSendMask);

		return true;
	}

	return false;
}

void
AppleCIOMeshPreparedCommand::setWholeBufferPrepared(bool wholeBuffer)
{
	_wholeBufferPrepared = wholeBuffer;
}

void
AppleCIOMeshPreparedCommand::dispatch(bool reverse, char * tag, size_t tagSz)
{
	if (UNLIKELY(!_preparedForUCSend)) {
		return;
	} else {
		for (uint8_t i = 0; i < _commandCount; i++) {
			_commands[i]->setTrailerData(tag, (uint32_t)tagSz);
		}

		if (reverse) {
			if (_commandCount == 1) {
				if ((_pendingSendMask & (0x1 << 0)) == 0) {
					goto done;
				}

				_commandMeshLinks[0]->sendData(_sourceNode, (int64_t)_offset,
				                               _wholeBufferPrepared ? _tbtCommands[0][_tbtCommandsLength - 1] : nullptr);

				_pendingSendMask ^= (0x1 << 0);
				_commands[0]->dataOut();
				_commandsProvider->txDispatched();
			} else if (_commandCount == 2) {
				if ((_pendingSendMask & (0x1 << 1)) == 0) {
					goto next_r_2_0;
				}

				_commandMeshLinks[1]->sendData(_sourceNode, (int64_t)_offset,
				                               _wholeBufferPrepared ? _tbtCommands[1][_tbtCommandsLength - 1] : nullptr);

				_pendingSendMask ^= (0x1 << 1);
				_commands[1]->dataOut();
				_commandsProvider->txDispatched();

			next_r_2_0:
				if ((_pendingSendMask & (0x1 << 0)) == 0) {
					goto done;
				}

				_commandMeshLinks[0]->sendData(_sourceNode, (int64_t)_offset,
				                               _wholeBufferPrepared ? _tbtCommands[0][_tbtCommandsLength - 1] : nullptr);

				_pendingSendMask ^= (0x1 << 0);
				_commands[0]->dataOut();
				_commandsProvider->txDispatched();
			} else if (_commandCount == 3) {
				if ((_pendingSendMask & (0x1 << 2)) == 0) {
					goto next_r_3_1;
				}

				_commandMeshLinks[2]->sendData(_sourceNode, (int64_t)_offset,
				                               _wholeBufferPrepared ? _tbtCommands[2][_tbtCommandsLength - 1] : nullptr);

				_pendingSendMask ^= (0x1 << 2);
				_commands[2]->dataOut();
				_commandsProvider->txDispatched();

			next_r_3_1:
				if ((_pendingSendMask & (0x1 << 1)) == 0) {
					goto next_r_3_0;
				}

				_commandMeshLinks[1]->sendData(_sourceNode, (int64_t)_offset,
				                               _wholeBufferPrepared ? _tbtCommands[1][_tbtCommandsLength - 1] : nullptr);

				_pendingSendMask ^= (0x1 << 1);
				_commands[1]->dataOut();
				_commandsProvider->txDispatched();

			next_r_3_0:
				if ((_pendingSendMask & (0x1 << 0)) == 0) {
					goto done;
				}

				_commandMeshLinks[0]->sendData(_sourceNode, (int64_t)_offset,
				                               _wholeBufferPrepared ? _tbtCommands[0][_tbtCommandsLength - 1] : nullptr);

				_pendingSendMask ^= (0x1 << 0);
				_commands[0]->dataOut();
				_commandsProvider->txDispatched();
			} else if (_commandCount == 4) {
				if ((_pendingSendMask & (0x1 << 3)) == 0) {
					goto next_r_4_2;
				}

				_commandMeshLinks[3]->sendData(_sourceNode, (int64_t)_offset,
				                               _wholeBufferPrepared ? _tbtCommands[3][_tbtCommandsLength - 1] : nullptr);

				_pendingSendMask ^= (0x1 << 3);
				_commands[3]->dataOut();
				_commandsProvider->txDispatched();

			next_r_4_2:
				if ((_pendingSendMask & (0x1 << 2)) == 0) {
					goto next_r_4_1;
				}

				_commandMeshLinks[2]->sendData(_sourceNode, (int64_t)_offset,
				                               _wholeBufferPrepared ? _tbtCommands[2][_tbtCommandsLength - 1] : nullptr);

				_pendingSendMask ^= (0x1 << 2);
				_commands[2]->dataOut();
				_commandsProvider->txDispatched();

			next_r_4_1:
				if ((_pendingSendMask & (0x1 << 1)) == 0) {
					goto next_r_4_0;
				}

				_commandMeshLinks[1]->sendData(_sourceNode, (int64_t)_offset,
				                               _wholeBufferPrepared ? _tbtCommands[1][_tbtCommandsLength - 1] : nullptr);

				_pendingSendMask ^= (0x1 << 1);
				_commands[1]->dataOut();
				_commandsProvider->txDispatched();

			next_r_4_0:
				if ((_pendingSendMask & (0x1 << 0)) == 0) {
					goto done;
				}

				_commandMeshLinks[0]->sendData(_sourceNode, (int64_t)_offset,
				                               _wholeBufferPrepared ? _tbtCommands[0][_tbtCommandsLength - 1] : nullptr);

				_pendingSendMask ^= (0x1 << 0);
				_commands[0]->dataOut();
				_commandsProvider->txDispatched();
			}
		} else {
			if (_commandCount == 1) {
				if ((_pendingSendMask & (0x1 << 0)) == 0) {
					goto done;
				}

				_commandMeshLinks[0]->sendData(_sourceNode, (int64_t)_offset,
				                               _wholeBufferPrepared ? _tbtCommands[0][_tbtCommandsLength - 1] : nullptr);

				_pendingSendMask ^= (0x1 << 0);
				_commands[0]->dataOut();
				_commandsProvider->txDispatched();
			} else if (_commandCount == 2) {
				if ((_pendingSendMask & (0x1 << 0)) == 0) {
					goto next_2_1;
				}

				_commandMeshLinks[0]->sendData(_sourceNode, (int64_t)_offset,
				                               _wholeBufferPrepared ? _tbtCommands[0][_tbtCommandsLength - 1] : nullptr);

				_pendingSendMask ^= (0x1 << 0);
				_commands[0]->dataOut();
				_commandsProvider->txDispatched();

			next_2_1:
				if ((_pendingSendMask & (0x1 << 1)) == 0) {
					goto done;
				}

				_commandMeshLinks[1]->sendData(_sourceNode, (int64_t)_offset,
				                               _wholeBufferPrepared ? _tbtCommands[1][_tbtCommandsLength - 1] : nullptr);

				_pendingSendMask ^= (0x1 << 1);
				_commands[1]->dataOut();
				_commandsProvider->txDispatched();
			} else if (_commandCount == 3) {
				if ((_pendingSendMask & (0x1 << 0)) == 0) {
					goto next_3_1;
				}

				_commandMeshLinks[0]->sendData(_sourceNode, (int64_t)_offset,
				                               _wholeBufferPrepared ? _tbtCommands[0][_tbtCommandsLength - 1] : nullptr);

				_pendingSendMask ^= (0x1 << 0);
				_commands[0]->dataOut();
				_commandsProvider->txDispatched();

			next_3_1:
				if ((_pendingSendMask & (0x1 << 1)) == 0) {
					goto next_3_2;
				}

				_commandMeshLinks[1]->sendData(_sourceNode, (int64_t)_offset,
				                               _wholeBufferPrepared ? _tbtCommands[1][_tbtCommandsLength - 1] : nullptr);

				_pendingSendMask ^= (0x1 << 1);
				_commands[1]->dataOut();
				_commandsProvider->txDispatched();

			next_3_2:
				if ((_pendingSendMask & (0x1 << 2)) == 0) {
					goto done;
				}

				_commandMeshLinks[2]->sendData(_sourceNode, (int64_t)_offset,
				                               _wholeBufferPrepared ? _tbtCommands[2][_tbtCommandsLength - 1] : nullptr);

				_pendingSendMask ^= (0x1 << 2);
				_commands[2]->dataOut();
				_commandsProvider->txDispatched();
			} else if (_commandCount == 4) {
				if ((_pendingSendMask & (0x1 << 0)) == 0) {
					goto next_4_1;
				}

				_commandMeshLinks[0]->sendData(_sourceNode, (int64_t)_offset,
				                               _wholeBufferPrepared ? _tbtCommands[0][_tbtCommandsLength - 1] : nullptr);

				_pendingSendMask ^= (0x1 << 0);
				_commands[0]->dataOut();
				_commandsProvider->txDispatched();

			next_4_1:
				if ((_pendingSendMask & (0x1 << 1)) == 0) {
					goto next_4_2;
				}

				_commandMeshLinks[1]->sendData(_sourceNode, (int64_t)_offset,
				                               _wholeBufferPrepared ? _tbtCommands[1][_tbtCommandsLength - 1] : nullptr);

				_pendingSendMask ^= (0x1 << 1);
				_commands[1]->dataOut();
				_commandsProvider->txDispatched();

			next_4_2:
				if ((_pendingSendMask & (0x1 << 2)) == 0) {
					goto next_4_3;
				}

				_commandMeshLinks[2]->sendData(_sourceNode, (int64_t)_offset,
				                               _wholeBufferPrepared ? _tbtCommands[2][_tbtCommandsLength - 1] : nullptr);

				_pendingSendMask ^= (0x1 << 2);
				_commands[2]->dataOut();
				_commandsProvider->txDispatched();

			next_4_3:
				if ((_pendingSendMask & (0x1 << 3)) == 0) {
					goto done;
				}

				_commandMeshLinks[3]->sendData(_sourceNode, (int64_t)_offset,
				                               _wholeBufferPrepared ? _tbtCommands[3][_tbtCommandsLength - 1] : nullptr);

				_pendingSendMask ^= (0x1 << 3);
				_commands[3]->dataOut();
				_commandsProvider->txDispatched();
			}
		}

	done:
		_preparedForUCSend = _pendingSendMask;
	}
}

bool
AppleCIOMeshPreparedCommand::prepared()
{
	return !(atomic_load(&_holdingForPrepare));
}

// MARK: - Assignment helper class

AppleCIOMeshAssignment *
AppleCIOMeshAssignment::allocate(AppleCIOMeshSharedMemory * provider, MUCI::MeshDirection direction)
{
	auto assignment = OSTypeAlloc(AppleCIOMeshAssignment);
	if (assignment != nullptr && !assignment->initialize(provider, direction)) {
		OSSafeReleaseNULL(assignment);
	}
	return assignment;
}

bool
AppleCIOMeshAssignment::initialize(AppleCIOMeshSharedMemory * provider, MUCI::MeshDirection direction)
{
	_provider        = provider;
	_direction       = direction;
	_linksPerChannel = (uint8_t)_provider->getProvider()->getLinksPerChannel();
	_assignedRXNode  = MCUCI::kUnassignedNode;

	for (int i = 0; i < kMaxAssignmentChunks; i++) {
		_offsets[i]          = (int64_t)-1;
		_preparedCommands[i] = NULL;
	}
	_offsetIdx = 0;

	for (int i = 0; i < kMaxMeshLinksPerChannel; i++) {
		_lastOffsets[i]  = -1;
		_firstOffsets[i] = -1;
	}

	return true;
}

void
AppleCIOMeshAssignment::free()
{
	super::free();
}

void
AppleCIOMeshAssignment::setRXAssignedNode(MCUCI::NodeId node)
{
	assertf(_direction == MUCI::MeshDirection::In, "Can only set RX assigned node for MeshDirection::In assignment");
	_assignedRXNode = node;
}

MUCI::MeshDirection
AppleCIOMeshAssignment::getDirection()
{
	return _direction;
}

AppleCIOMeshSharedMemory *
AppleCIOMeshAssignment::getProvider()
{
	return _provider;
}

size_t
AppleCIOMeshAssignment::getAssignmentSizePerLink()
{
	return (_offsetIdx * (_provider->_sharedMemory.chunkSize)) / _linksPerChannel;
}

void
AppleCIOMeshAssignment::addOffset(int64_t offset, AppleCIOMeshPreparedCommand * preparedCommand)
{
	if (_offsetIdx < kMaxAssignmentChunks) {
		_offsets[_offsetIdx]          = offset;
		_preparedCommands[_offsetIdx] = preparedCommand;
		_offsetIdx++;
	}
}

void
AppleCIOMeshAssignment::addLastOffset(int64_t offset, uint8_t linkIter, AppleCIOMeshPreparedCommand * preparedCommand)
{
	_lastOffsets[linkIter]          = offset;
	_preparedLastCommands[linkIter] = preparedCommand;
}

void
AppleCIOMeshAssignment::addFirstOffset(int64_t offset, uint8_t linkIter, AppleCIOMeshPreparedCommand * preparedCommand)
{
	assertf(_firstOffsets[linkIter] == -1, "Adding multiple first offsets for the same linkIter[%d]. Previous firstOffset:%lld\n",
	        linkIter, _firstOffsets[linkIter]);
	_firstOffsets[linkIter]          = offset;
	_preparedFirstCommands[linkIter] = preparedCommand;
}

void
AppleCIOMeshAssignment::prepare(uint8_t linkMask)
{
	// when prepare is called with linkmask = 0x3, this is a full prepare or prepare all, so we can hold the entire
	// assignment (it is no longer ready to notify userspace the transfer has completed). in the case of drip prepare
	//(which is done with SendAndPrepare), we do not want to make the whole assignment as ready, it will be marked ready
	// as the commandeer thread drips through all the assignments preparing them.
	if (linkMask == 0x3) {
		hold();
	}

	for (int i = 0; i < _offsetIdx; i++) {
		// ugh this is gross, should make this a bit less hacky.
		if (linkMask != 0x3) {
			if (linkMask == 0x1) {
				if (i % 2 == 1) {
					continue;
				}
			} else if (linkMask == 0x2) {
				if (i % 2 == 0) {
					continue;
				}
			}
		}

		if (_direction == MUCI::MeshDirection::In) {
			_provider->_prepareRxCommand(_offsets[i]);
		} else if (_preparedCommands[i]) {
			_preparedCommands[i]->prepareCommands(linkMask != 0x3);
		} else {
			panic("No preparedTxCommand for offset %lld?!\n", _offsets[i]);
		}
	}
}

void
AppleCIOMeshAssignment::markForwardIncomplete()
{
	for (int i = 0; i < _linksPerChannel; i++) {
		assertf(_lastOffsets[i] != -1,
		        "marking forward incomplete for an assignment when no lastlink offset has been defined at index: %d", i);

		auto meshTbtCommand = _provider->getThunderboltCommands(_lastOffsets[i]);

		// If this is a forwarding command, and it is not part of a forward chain.
		if (_direction == MUCI::MeshDirection::In && meshTbtCommand->isTxForwarding() && !meshTbtCommand->inForwardChain()) {
			meshTbtCommand->markTxForwardIncomplete();
		}
	}
}

bool
AppleCIOMeshAssignment::dripPrepare(int64_t * offsetIdx, int64_t * linkIdx)
{
	assertf(_direction == MUCI::MeshDirection::Out, "Can only prepare offset at index for output assignments");
	assertf(_preparedCommands[*offsetIdx], "No preparedTxCommand for offset %lld\n", _offsets[*offsetIdx]);

	if (_preparedCommands[*offsetIdx]->dripPrepare(linkIdx)) {
		*offsetIdx = (*offsetIdx) + 1;
		*linkIdx   = 0;
	}

	if (*offsetIdx == _offsetIdx) {
		for (int i = 0; i < _ready.length(); i++) {
			_ready[i] = false;
		}

		return true;
	}

	return false;
}

void
AppleCIOMeshAssignment::hold()
{
	for (int i = 0; i < _ready.length(); i++) {
		_ready[i] = false;
	}

	if (_direction == MUCI::MeshDirection::In) {
		for (int i = 0; i < _offsetIdx; i++) {
			_provider->_holdRxCommand(_offsets[i]);
		}
	} else {
		for (int i = 0; i < _offsetIdx; i++) {
			_preparedCommands[i]->holdCommands();
		}
	}
}

void
AppleCIOMeshAssignment::submit(uint8_t linkChannelMask, char * tag, size_t tagSz)
{
	assertf(_direction == MUCI::MeshDirection::Out, "Cannot submit input assignment commands. Offset: %llx", _offsets[0]);

	// Go through all firstOffsets and dispatch links for those offsets
	// We do not need to submit all offsets because every command is prepared
	// and the TX path just needs 1 PIO update.
	// This does not work that well because the offset is what is used to
	// access this assignment, but we are checking against the last offset.
	// The command will not check if the data has come in anymore and will always
	// check for TX completion. It will rely on the caller properly keeping track
	// of submissions being complete or being okay with unnecesary completion
	// checks.

	// Check if the last command for the link is prepared too.

	if (linkChannelMask & 0x1 && _preparedLastCommands[0]->prepared()) {
		assertf(_firstOffsets[0] != -1, "submitting an assignment when no firstlink offset has been defined at index: %d", 0);
		_preparedFirstCommands[0]->dispatch(false, tag, tagSz);
		if (linkChannelMask & 0x2) {
			// we're also going to be sending on the other link so advance the tag pointer
			assertf(tagSz >= 2 * kTagSize, "tagSz %zd is not big enough - need %d\n", tagSz, 2 * kTagSize);
			tag += kTagSize;
		}
	}

	if (_linksPerChannel > 1 && linkChannelMask & 0x2 && _preparedLastCommands[1]->prepared()) {
		assertf(_firstOffsets[1] != -1, "submitting an assignment when no firstlink offset has been defined at index: %d", 1);
		_preparedFirstCommands[1]->dispatch(true, tag, tagSz);
	}
}

void
AppleCIOMeshAssignment::setWholeBufferPrepared(bool wholeBuffer)
{
	assertf(_direction == MUCI::MeshDirection::Out, "Cannot prepare a whole buffer for input");

	for (int i = 0; i < _offsetIdx; i++) {
		_preparedCommands[i]->setWholeBufferPrepared(wholeBuffer);
	}
}

bool
AppleCIOMeshAssignment::checkPrepared()
{
	bool prepared = true;

	prepared &= (_preparedLastCommands[0]->prepared()) && !_ready[0];
	if (_linksPerChannel > 1) {
		prepared &= (_preparedLastCommands[1]->prepared()) && !_ready[1];
	}

	return prepared;
}

bool
AppleCIOMeshAssignment::checkForwardComplete()
{
	bool forwardComplete = true;

	for (int i = 0; i < _linksPerChannel; i++) {
		assertf(_lastOffsets[i] != -1, "forwarding an assignment when no lastlink offset has been defined at index: %d", i);

		auto meshTbtCommand = _provider->getThunderboltCommands(_lastOffsets[i]);
		if (_direction == MUCI::MeshDirection::In) {
			forwardComplete &= meshTbtCommand->isTxForwardComplete();
		}
	}

	return forwardComplete;
}

bool
AppleCIOMeshAssignment::checkReady()
{
	// Check on all last offsets links one after the other.
	bool isReady = true;

	for (int i = 0; i < _linksPerChannel; i++) {
		assertf(_lastOffsets[i] != -1, "submitting an assignment when no lastlink offset has been defined at index: %d", i);
		if (_ready[i]) {
			continue;
		}

		auto meshTbtCommand = _provider->getThunderboltCommands(_lastOffsets[i]);
		if (_direction == MUCI::MeshDirection::In) {
			if (_assignedRXNode == MCUCI::kUnassignedNode) {
				_ready[i] = meshTbtCommand->checkRxReady();
			} else {
				_ready[i] = meshTbtCommand->checkRxReadyForNode(_assignedRXNode);
			}
			isReady &= _ready[i];
		} else {
			_ready[i] = meshTbtCommand->checkTxReady();
			isReady &= _ready[i];
		}
	}

	return isReady;
}

bool
AppleCIOMeshAssignment::checkTXReady(uint8_t linkChannelMask)
{
	assertf(_direction == MUCI::MeshDirection::Out, "checkTXReady can only be called on Out assignments");

	// Check on all last offsets links one after the other.
	bool isReady = true;

	if (isReady && (linkChannelMask & 0x1)) {
		assertf(_lastOffsets[0] != -1, "submitting an assignment when no lastlink offset has been defined at index: %d", 0);
		if (_ready[0]) {
			goto nextCheck;
		}

		auto meshTbtCommand = _provider->getThunderboltCommands(_lastOffsets[0]);
		_ready[0]           = meshTbtCommand->checkTxReady();
		isReady &= _ready[0];
	}

nextCheck:
	if (_linksPerChannel > 1 && isReady && (linkChannelMask & 0x2)) {
		assertf(_lastOffsets[1] != -1, "submitting an assignment when no lastlink offset has been defined at index: %d", 1);
		if (_ready[1]) {
			goto done;
		}

		auto meshTbtCommand = _provider->getThunderboltCommands(_lastOffsets[1]);
		_ready[1]           = meshTbtCommand->checkTxReady();
		isReady &= _ready[1];
	}

done:
	return isReady;
}

bool
AppleCIOMeshAssignment::getTrailer(uint8_t linkChannelIdx, char * tag, size_t tagSz)
{
	assertf(_direction == MUCI::MeshDirection::In, "getTrailer is only applicable to input");

	bool retVal                                   = false;
	AppleCIOMeshThunderboltCommands * tbtCommands = nullptr;

	if (linkChannelIdx == 0) {
		retVal      = _ready[0];
		tbtCommands = _provider->getThunderboltCommands(_lastOffsets[0]);
	} else if (_linksPerChannel > 1 && linkChannelIdx == 1) {
		retVal      = _ready[1];
		tbtCommands = _provider->getThunderboltCommands(_lastOffsets[1]);
	}

	if (retVal) {
		uint64_t * trailer = (uint64_t *)tbtCommands->getTrailer();
		memcpy(tag, trailer, tagSz);
	}

	return retVal;
}

bool
AppleCIOMeshAssignment::isReady()
{
	// Check on all last offsets links one after the other.
	bool isReady = true;

	assertf(_lastOffsets[0] != -1, "submitting an assignment when no lastlink offset has been defined at index: %d", 0);
	if (!_ready[0]) {
		return false;
	}

	assertf(_lastOffsets[1] != -1, "submitting an assignment when no lastlink offset has been defined at index: %d", 1);
	if (!_ready[1]) {
		return false;
	}

	return isReady;
}

bool
AppleCIOMeshAssignment::isDispatched(uint8_t linkChannelMask)
{
	assertf(_direction == MUCI::MeshDirection::Out, "Cannot check input assignment dispatched");
	bool retVal = true;

	if (retVal && (linkChannelMask & 0x1)) {
		assertf(_firstOffsets[0] != -1, "checking dispatch on an assignment when no firstlink offset has been defined at index: %d",
		        0);

		auto command = _provider->getThunderboltCommands(_firstOffsets[0]);
		retVal &= command->finishedTxDispatch();
	}

	if (retVal && _linksPerChannel > 1 && (linkChannelMask & 0x2)) {
		assertf(_firstOffsets[1] != -1, "checking dispatch on an assignment when no firstlink offset has been defined at index: %d",
		        1);

		auto command = _provider->getThunderboltCommands(_firstOffsets[1]);
		retVal &= command->finishedTxDispatch();
	}

	return retVal;
}

void
AppleCIOMeshAssignment::printState()
{
	IOLog("CIOMeshSharedMemory: -> \t Direction: %s\n", _direction == MUCI::MeshDirection::In ? "In" : "Out");

	IOLog("CIOMeshSharedMemory: -> \t Offsets:");
	for (unsigned int i = 0; i < _offsetIdx; i++) {
		IOLog("0x%.8llx,", _offsets[i]);
	}
	IOLog("\n");

	IOLog("CIOMeshSharedMemory: -> \t LastOffsets:");
	for (unsigned int i = 0; i < _provider->getProvider()->getLinksPerChannel(); i++) {
		IOLog("0x%.8llx,", _lastOffsets[i]);
	}
	IOLog("\n");

	IOLog("CIOMeshSharedMemory: -> \t FirstOffsets:");
	for (unsigned int i = 0; i < _provider->getProvider()->getLinksPerChannel(); i++) {
		IOLog("0x%.8llx,", _firstOffsets[i]);
	}
	IOLog("\n");

	IOLog("CIOMeshSharedMemory: -> \t Ready:");
	for (unsigned int i = 0; i < _provider->getProvider()->getLinksPerChannel(); i++) {
		IOLog("%d,", _ready[i]);
	}
	IOLog("\n");
}

void
AppleCIOMeshAssignment::dumpReadyState()
{
	for (int i = 0; i < _linksPerChannel; i++) {
		assertf(_lastOffsets[i] != -1, "submitting an assignment when no lastlink offset has been defined at index: %d", i);

		auto meshTbtCommand = _provider->getThunderboltCommands(_lastOffsets[i]);
		bool ready;
		if (_direction == MUCI::MeshDirection::In) {
			ready = meshTbtCommand->checkRxReady();
		} else {
			ready = meshTbtCommand->checkTxReady();
		}
		LOG("link %d: offset 0x%llx ready %s direction %s\n", i, _lastOffsets[i], ready ? "YES" : "NO",
		    _direction == MUCI::MeshDirection::In ? "IN" : "OUT");
	}
}

int64_t
AppleCIOMeshAssignment::tmp2()
{
	return _provider->getId();
}

// MARK: - Assignment Map helper class

void
AppleCIOMeshAssignmentMap::addAssignmentForNode(MCUCI::NodeId node, uint8_t idx)
{
	nodeMap[node].node                                     = node;
	nodeMap[node].assignedIdx[nodeMap[node].assignCount++] = idx;
	nodeMap[node].provider                                 = this;
}

void
AppleCIOMeshAssignmentMap::addLinkAssignmentForNode(MCUCI::NodeId node, uint8_t idx, uint8_t link)
{
	auto tmp = nodeMap[node].linkAssignCount[link];

	nodeMap[node].linkAssignedIdx[link][tmp] = idx;
	nodeMap[node].linkAssignCount[link] += 1;
}

bool
AppleCIOMeshAssignmentMap::checkAllReady(bool * interrupted)
{
	bool retVal = true;
	for (int i = 0; i < assignmentCount; i++) {
		if (!assignmentReady[i]) {
			assignmentReady[i] = sharedMemory->checkAssignmentReady(assignmentOffset[i], interrupted);
			if (assignmentReady[i]) {
				sharedMemory->readAssignmentTagForLink(assignmentOffset[i], linkIdx[i], &assignmentTag[i][0],
				                                       sizeof(assignmentTag[i]));
			}
			retVal &= assignmentReady[i];
			if (*interrupted) {
				retVal = false;
				break;
			}
		}
	}

	return retVal;
}

bool
AppleCIOMeshAssignmentMap::checkReady(uint32_t idx, bool * interrupted)
{
	assignmentReady[idx] = sharedMemory->checkAssignmentReady(assignmentOffset[idx], interrupted);
	if (assignmentReady[idx]) {
		sharedMemory->readAssignmentTagForLink(assignmentOffset[idx], linkIdx[idx], &assignmentTag[idx][0],
		                                       sizeof(assignmentTag[idx]));
	}

	return assignmentReady[idx];
}

void
AppleCIOMeshAssignmentMap::hold()
{
	for (int i = 0; i < assignmentCount; i++) {
		if (linkIdx[i] == 0) {
			auto offset = getAssignmentOffset(i);
			sharedMemory->holdCommand(offset);
		}
	}
}

void
AppleCIOMeshAssignmentMap::reset()
{
	atomic_store(&allReceiveFinished, true);
	for (int i = 0; i < assignmentCount; i++) {
		assignmentReady[i]    = false;
		assignmentNotified[i] = false;
	}
	for (int i = 0; i < kMaxCIOMeshNodes; i++) {
		for (int j = 0; j < kMaxMeshLinksPerChannel; j++) {
			atomic_store(&nodeMap[i].linkCurrentIdx[j], 0);
			nodeMap[i].totalPrepared[j] = 0;
		}
	}
	atomic_store(&remainingAssignments, assignmentCount);
}

uint8_t
AppleCIOMeshAssignmentMap::getIdxForOffset(int64_t offset)
{
	for (uint8_t i = 0; i < assignmentCount; i++) {
		if (assignmentOffset[i] == offset) {
			return i;
		}
	}

	return kMaxAssignmentCount;
}

int64_t
AppleCIOMeshAssignmentMap::getAssignmentOffset(uint32_t idx)
{
	return assignmentOffset[idx] + (linkIdx[idx] * sharedMemory->getChunkSize());
}

bool
AppleCIOMeshAssignmentMap::checkPrepared()
{
	bool retVal = true;
	for (int i = 0; i < assignmentCount && retVal; i++) {
		retVal &= sharedMemory->checkAssignmentPrepared(assignmentOffset[i]);
	}

	return retVal;
}

void
AppleCIOMeshAssignmentMap::dump()
{
	for (int i = 0; i < 8; i++) {
		LOG("NodeMap[%d]===\n", i);
		auto tmp = nodeMap[i];
		for (int j = 0; j < tmp.assignCount; j++) {
			LOG("[%d] = %d\n", j, tmp.assignedIdx[j]);
		}
		LOG("------\n");
		for (int l = 0; l < 2; l++) {
			LOG("link:%d curIdx:%d totalPrepared:%lld\n", l, tmp.linkCurrentIdx[l], tmp.totalPrepared[l]);
			for (int j = 0; j < tmp.linkAssignCount[l]; j++) {
				auto assignment = sharedMemory->getAssignment(getAssignmentOffset(tmp.linkAssignedIdx[0][j]));
				LOG("[%d] = %d .. %llx\n", j, tmp.linkAssignedIdx[l][j], assignment->tmp());
			}
		}
	}
}
