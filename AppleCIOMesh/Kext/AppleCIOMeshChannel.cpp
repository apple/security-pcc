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

#include "AppleCIOMeshChannel.h"
#include "AppleCIOMeshControlPath.h"
#include "AppleCIOMeshLink.h"
#include "AppleCIOMeshService.h"

#define LOG_PREFIX "AppleCIOMeshChannel"
#include "Util/Error.h"
#include "Util/Log.h"
#include "Util/ReturnCode.h"

OSDefineMetaClassAndStructors(AppleCIOMeshChannel, OSObject);

AppleCIOMeshChannel *
AppleCIOMeshChannel::allocate(AppleCIOMeshService * provider,
                              MCUCI::NodeId node,
                              MCUCI::PartitionIdx partition,
                              MCUCI::NodeId partner,
                              HardwareNodeId partnerHardwareId,
                              MCUCI::MeshChannelIdx channelIndex)
{
	auto channel = OSTypeAlloc(AppleCIOMeshChannel);
	if (channel != nullptr && !channel->initialize(provider, node, partition, partner, partnerHardwareId, channelIndex)) {
		OSSafeReleaseNULL(channel);
	}
	return channel;
}

bool
AppleCIOMeshChannel::initialize(AppleCIOMeshService * provider,
                                MCUCI::NodeId node,
                                MCUCI::PartitionIdx partition,
                                MCUCI::NodeId partner,
                                HardwareNodeId partnerHardwareId,
                                MCUCI::MeshChannelIdx channelIndex)
{
	_provider          = provider;
	_node              = node;
	_partition         = partition;
	_partner           = partner;
	_partnerHardwareId = partnerHardwareId;
	_channelIndex      = channelIndex;

	for (int i = 0; i < kMaxMeshLinksPerChannel; i++) {
		_links[i]          = nullptr;
		_agentLinkState[i] = AgentLinkState::Unknown;
		_linkIndices[i]    = 0xFF;
	}

	for (int i = 0; i < kNumDataPaths; i++) {
		_neighborTxAssignments[i] = {
		    .sourceNode = MCUCI::kUnassignedNode,
		    .pathIndex  = -1,
		    .rxAssigned = false,
		};
	}

	_isPrincipal = node < partner;
	_ready       = false;
	_verified    = false;

	return true;
}

uint8_t
AppleCIOMeshChannel::getLinkIndex(uint8_t idx)
{
	return _linkIndices[idx];
}

MCUCI::NodeId
AppleCIOMeshChannel::getLocalNodeId()
{
	return _node;
}

MCUCI::NodeId
AppleCIOMeshChannel::getExtendedNodeId()
{
	return _partition * 8 + _node;
}

MCUCI::PartitionIdx
AppleCIOMeshChannel::getPartitionIndex()
{
	return _partition;
}

MCUCI::NodeId
AppleCIOMeshChannel::getPartnerNodeId()
{
	return _partner;
}

HardwareNodeId
AppleCIOMeshChannel::getPartnerHardwareId()
{
	return _partnerHardwareId;
}

MCUCI::MeshChannelIdx
AppleCIOMeshChannel::getChannelIndex()
{
	return _channelIndex;
}

bool
AppleCIOMeshChannel::getConnectedChassisId(MCUCI::ChassisId * chassisId)
{
	if (!isReady() || _links[0] == nullptr) {
		return false;
	}

	_links[0]->getChassisId(chassisId);
	return true;
}

bool
AppleCIOMeshChannel::isReady()
{
	return _verified;
}

bool
AppleCIOMeshChannel::isPartnerTxReady(MCUCI::NodeId sourceNodeId)
{
	// Lookup txAssigned table to see if TX data path is ready for the source nodeID
	for (int i = 0; i < kNumDataPaths; i++) {
		if (_neighborTxAssignments[i].sourceNode == sourceNodeId) {
			return true;
		}
	}
	return false;
}

void
AppleCIOMeshChannel::addLink(AppleCIOMeshLink * link, uint8_t linkIndex)
{
	// Add link to the first free available slot
	for (int i = 0; i < _provider->getLinksPerChannel(); i++) {
		if (_links[i] == nullptr) {
			_links[i]       = link;
			_linkIndices[i] = linkIndex;
			break;
		}
	}

	// Set the primary control right here if it continues link id registration
	// after this.
	if (_isPrincipal) {
		_primaryControl = _links[0]->getControlPath();
	}

	// Check if all links have registered
	for (int i = 0; i < _provider->getLinksPerChannel(); i++) {
		if (_links[i] == nullptr) {
			return;
		}
	}

	LOG("All links registered with partner: %d. Self: node %d in partition %d.\n", _partner, _node, _partition);

	if (_isPrincipal) {
		if (_provider->getLinksPerChannel() == 1) {
			_secondaryControl = _links[0]->getControlPath();
		} else if (_provider->getLinksPerChannel() == 2) {
			_secondaryControl = _links[1]->getControlPath();
		} else {
			panic("Unsupported number of mesh links per channel: %d\n", _provider->getLinksPerChannel());
		}
	}
}

void
AppleCIOMeshChannel::removeLink(AppleCIOMeshLink * link)
{
	for (int i = 0; i < _provider->getLinksPerChannel(); i++) {
		if (_links[i] == link) {
			_links[i] = nullptr;
			break;
		}
	}

	for (int i = 0; i < kNumDataPaths; i++) {
		_neighborTxAssignments[i] = {
		    .sourceNode = MCUCI::kUnassignedNode,
		    .pathIndex  = -1,
		    .rxAssigned = false,
		};
	}

	_ready    = false;
	_verified = false;
}

void
AppleCIOMeshChannel::sendPendingNodeRegisters()
{
	// apply any pending link identifications
	// if we are the principal here, we will ask the agent to swap
	// even before we send out our node identification
	// Or, we will send it out, and then ask them to swap
	// not a big deal, we are principal, and our secondaryLinkState is all
	// that matters
	// If we are not principal, then we will do nothing and simply
	// send out our node identification.
	for (int i = 0; i < _provider->getLinksPerChannel(); i++) {
		if (_links[i] != nullptr) {
			LinkIdentificationCommand cmd;
			if (_links[i]->getPendingLinkId(&cmd)) {
				connectingNodeRegister(_links[i], cmd.nodeId, cmd.linkIdx);
			}
		}
	}
}

void
AppleCIOMeshChannel::connectingNodeRegister(AppleCIOMeshLink * link, __unused MCUCI::NodeId partner, uint8_t partnerLinkIdx)
{
	if (!_isPrincipal) {
		return;
	}

	if (_primaryControl == nullptr) {
		LOG("### I am the principal but have a null primaryControl?  _secondaryControl %p\n", _secondaryControl);
		return;
	}

	if (_links[partnerLinkIdx] == link) {
		_agentLinkState[partnerLinkIdx] = AgentLinkState::IdentifiedMatch;
	} else {
		_agentLinkState[partnerLinkIdx] = AgentLinkState::IdentifiedMismatch;
	}

	// Check if we got both identifications
	for (int i = 0; i < _provider->getLinksPerChannel(); i++) {
		if (_agentLinkState[i] == AgentLinkState::Unknown) {
			return;
		}
	}

	// if both are match, then the channel is ready
	if (_agentLinkState[0] == AgentLinkState::IdentifiedMatch) {
		// principal of this channel sends ChannelReady
		_ready = true;

		MeshControlCommand cmd;
		cmd.commandType = MeshControlCommandType::ChannelReady;

		cmd.data.channelReady.nodeIdA = _node;
		cmd.data.channelReady.nodeIdB = _partner;

		_primaryControl->submitControlCommand(&cmd);

		return;
	}

	// Link order is not correct, request a swap
	for (int i = 0; i < _provider->getLinksPerChannel(); i++) {
		_agentLinkState[i] = AgentLinkState::Unknown;
	}

	MeshControlCommand cmd;
	cmd.commandType = MeshControlCommandType::ChannelLinkSwap;
	_primaryControl->submitControlCommand(&cmd);
}

void
AppleCIOMeshChannel::channelSwapRequested()
{
	if (_provider->getLinksPerChannel() != 2) {
		LOG("Swap is only supported for 2 links per channel\n");
		return;
	}

	auto tmp  = _links[0];
	_links[0] = _links[1];
	_links[1] = tmp;

	auto tmpIndex   = _linkIndices[0];
	_linkIndices[0] = _linkIndices[1];
	_linkIndices[1] = tmpIndex;

	_ready = false;

	sendNodeIdentification();
}

void
AppleCIOMeshChannel::channelReady(MCUCI::NodeId principal, MCUCI::NodeId agent)
{
	_ready          = true;
	_primaryControl = _links[0]->getControlPath();
	if (_provider->getLinksPerChannel() == 1) {
		_secondaryControl = _links[0]->getControlPath();
	} else if (_provider->getLinksPerChannel() == 2) {
		_secondaryControl = _links[1]->getControlPath();
	} else {
		panic("Unsupported number of mesh links per channel: %d\n", _provider->getLinksPerChannel());
	}

	// Agent now sends a ping on the primaryControl path
	// Principal will send a pong on the secondaryControl path
	MeshControlCommand cmd;
	cmd.commandType = MeshControlCommandType::PrimaryLinkPing;
	_primaryControl->submitControlCommand(&cmd);
}

void
AppleCIOMeshChannel::pingReceived(AppleCIOMeshLink * link)
{
	// now we send a pong on the secondary/other control path.
	MeshControlCommand cmd;
	cmd.commandType = MeshControlCommandType::SecondaryLinkPong;
	_secondaryControl->submitControlCommand(&cmd);

	_verified = true;

	// assign any pending RX now
	_assignPendingNeighborRXAssignments();
}

void
AppleCIOMeshChannel::pongReceived(AppleCIOMeshLink * link)
{
	_verified = true;
	_assignPendingNeighborRXAssignments();
}

void
AppleCIOMeshChannel::sendNodeIdentification()
{
	// Check if all links have registered
	for (int i = 0; i < _provider->getLinksPerChannel(); i++) {
		if (_links[i] == nullptr) {
			return;
		}
	}

	// Send LinkIdentification
	for (int i = 0; i < _provider->getLinksPerChannel(); i++) {
		// This is the only time we should access a link's control path directly
		// instead of using primary/secondary.
		auto controlPath = _links[i]->getControlPath();

		if (controlPath) {
			MeshControlCommand cmd;
			cmd.commandType = MeshControlCommandType::LinkIdentification;

			cmd.data.linkId.nodeId  = _links[i]->getService()->getLocalNodeId();
			cmd.data.linkId.linkIdx = (uint8_t)i;

			controlPath->submitControlCommand(&cmd);
		}
	}
}

void
AppleCIOMeshChannel::sendTxAssignmentNotification(MCUCI::NodeId sourceNodeId, uint32_t pathIndex)
{
	if (!isReady()) {
		panic("Cannot send TX assignment before channel isReady.");
	}

	MeshControlCommand cmd;
	cmd.commandType                    = MeshControlCommandType::TxAssignmentNotification;
	cmd.data.txAssignment.sourceNodeId = sourceNodeId;
	cmd.data.txAssignment.pathIndex    = pathIndex;
	_primaryControl->submitControlCommand(&cmd);

	return;
}

void
AppleCIOMeshChannel::receiveTxAssignmentNotification(TxAssignmentNotificationCommand * txAssignment)
{
	// Update txAssigned table with pathIndex and source nodeId
	if (_neighborTxAssignments[txAssignment->pathIndex].sourceNode != txAssignment->sourceNodeId) {
		LOG("Tx assignment source Node changed at path %d: %d -> %d link[%d]. Channel[%d]\n", txAssignment->pathIndex,
		    _neighborTxAssignments[txAssignment->pathIndex].sourceNode, txAssignment->sourceNodeId,
		    _primaryControl->getLink()->getController()->getRID(), _channelIndex);
	}

	_neighborTxAssignments[txAssignment->pathIndex].sourceNode = txAssignment->sourceNodeId;
	_neighborTxAssignments[txAssignment->pathIndex].pathIndex  = txAssignment->pathIndex;
	_neighborTxAssignments[txAssignment->pathIndex].rxAssigned = false;

	_assignPendingNeighborRXAssignments();

	return;
}

void
AppleCIOMeshChannel::sendControlCommand(MeshControlCommand * controlCommand)
{
	_primaryControl->submitControlCommand(controlCommand);
}

void
AppleCIOMeshChannel::sendRawControlMessage(MeshControlMessage * controlMessage)
{
	_primaryControl->submitControlMessage(controlMessage);
}

void
AppleCIOMeshChannel::_assignPendingNeighborRXAssignments()
{
	if (!isReady()) {
		return;
	}

	for (int r = 0; r < kNumDataPaths; r++) {
		if (_neighborTxAssignments[r].sourceNode == MCUCI::kUnassignedNode || _neighborTxAssignments[r].rxAssigned == true) {
			continue;
		}

		for (int i = 0; i < _provider->getLinksPerChannel(); i++) {
			auto assignedPath = _links[i]->assignRxNode(_neighborTxAssignments[r].sourceNode);
			if (assignedPath != _neighborTxAssignments[r].pathIndex) {
				panic("Partner assigned source[%d] to pathIndex[%d]. We assigned to pathIndex[%d]",
				      _neighborTxAssignments[r].sourceNode, _neighborTxAssignments[r].pathIndex, assignedPath);
			}
			LOG("Assigned RX path %d for sourceNode:%d. TXPath:%d\n", assignedPath, _neighborTxAssignments[r].sourceNode,
			    _neighborTxAssignments[r].pathIndex);
		}

		_neighborTxAssignments[r].rxAssigned = true;

		// Notify Userspace now
		MCUCI::NodeConnectionInfo connectionInfo = {
		    .channelIndex = _channelIndex,
		    .node         = _neighborTxAssignments[r].sourceNode,
		};
		_provider->notifyConnectionChange(connectionInfo, true, false);
	}
}
