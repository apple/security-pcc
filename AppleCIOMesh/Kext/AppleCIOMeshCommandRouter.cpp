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

#include "AppleCIOMeshCommandRouter.h"
#include "AppleCIOMeshService.h"

#define LOG_PREFIX "AppleCIOMeshCommandRouter"
#include "Signpost.h"
#include "Util/Error.h"
#include "Util/Log.h"
#include "Util/ReturnCode.h"

OSDefineMetaClassAndStructors(AppleCIOMeshCommandRouter, OSObject);

AppleCIOMeshCommandRouter *
AppleCIOMeshCommandRouter::withService(AppleCIOMeshService * provider)
{
	auto router = OSTypeAlloc(AppleCIOMeshCommandRouter);
	if (router != nullptr && !router->initWithService(provider)) {
		OSSafeReleaseNULL(router);
	}
	return router;
}

bool
AppleCIOMeshCommandRouter::initWithService(AppleCIOMeshService * provider)
{
	_provider = provider;

	for (uint32_t i = 0; i < _channelNodeMap.length(); i++) {
		_channelNodeMap[i] = MCUCI::kUnassignedNode;
	}

	for (uint32_t i = 0; i < _cioDestinationMap.length(); i++) {
		_cioDestinationMap[i] = -1;
	}

	for (uint32_t i = 0; i < _sourceCIOMap.length(); i++) {
		_sourceCIOMap[i] = -1;
	}

	return true;
}

void
AppleCIOMeshCommandRouter::addChannel(MCUCI::MeshChannelIdx channelIndex, MCUCI::NodeId node)
{
	_channelNodeMap[channelIndex] = node;
}

void
AppleCIOMeshCommandRouter::removeChannel(MCUCI::MeshChannelIdx channelIndex)
{
	_channelNodeMap[channelIndex] = MCUCI::kUnassignedNode;

	for (int i = 0; i < _cioDestinationMap.size(); i++) {
		if (_cioDestinationMap[i] == channelIndex) {
			_cioDestinationMap[i] = -1;
		}
	}

	for (int i = 0; i < _sourceCIOMap.size(); i++) {
		if (_sourceCIOMap[i] == channelIndex) {
			_sourceCIOMap[i] = -1;
		}
	}
}

void
AppleCIOMeshCommandRouter::removeAllChannels()
{
	for (int i = 0; i < _cioDestinationMap.size(); i++) {
		_cioDestinationMap[i] = -1;
	}

	for (int i = 0; i < _sourceCIOMap.size(); i++) {
		_sourceCIOMap[i] = -1;
	}
}

void
AppleCIOMeshCommandRouter::addRouteTo(MCUCI::NodeId receiver, MCUCI::NodeId forwarder)
{
	// if forwarder = self, then we get the cio channel from channelNodeMap
	if (forwarder == _provider->getLocalNodeId()) {
		int32_t cioChannelIdx = -1;
		for (uint32_t i = 0; i < _channelNodeMap.length(); i++) {
			if (_channelNodeMap[i] == receiver) {
				cioChannelIdx = (int32_t)i;
				break;
			}
		}

		if (cioChannelIdx == -1) {
			LOG("Adding a direct route to a node (receiver:%d forwarder:%d) before a channel to the receiver has been set",
			    receiver, forwarder);
			return;
		}

		_cioDestinationMap[receiver] = (int32_t)cioChannelIdx;
		return;
	}

	// if forwarder != self, then we get the _cioDestinationMap for that forwarder
	// and set it for this receiver
	int32_t cioChannelindex = _cioDestinationMap[forwarder];
	if (cioChannelindex == -1) {
		LOG("Adding a route through forwarder:%d to receiver:%d before a route to the forwarder has been set.", forwarder,
		    receiver);
		return;
	}

	_cioDestinationMap[receiver] = cioChannelindex;
}

void
AppleCIOMeshCommandRouter::addSourceNodeCIOChannel(MCUCI::NodeId node, MCUCI::MeshChannelIdx channelIndex)
{
	// node is unsigned so we don't have to check for < 0
	if (node < _sourceCIOMap.length()) {
		_sourceCIOMap[node] = channelIndex;
	} else {
		LOG("Node %d is outta bounds (0...%d)\n", node, _sourceCIOMap.length());
	}
}

MCUCI::MeshChannelIdx
AppleCIOMeshCommandRouter::getCIOChannelForDestination(MCUCI::NodeId destination)
{
	return (MCUCI::MeshChannelIdx)_cioDestinationMap[destination];
}

MCUCI::MeshChannelIdx
AppleCIOMeshCommandRouter::getSourceNodeCIOChannel(MCUCI::NodeId sourceNode)
{
	// sourceNode is unsigned so we don't have to check for < 0
	if (sourceNode >= _sourceCIOMap.length()) {
		LOG("SourceNode %d is outta bounds (0...%d)\n", sourceNode, _sourceCIOMap.length());
		return (MCUCI::MeshChannelIdx)-1;
	}
	return (MCUCI::MeshChannelIdx)_sourceCIOMap[sourceNode];
}

uint32_t
AppleCIOMeshCommandRouter::getNumNodesInMesh()
{
	// Start at 1 for self.
	uint32_t retVal = 1;

	for (uint32_t i = 0; i < _cioDestinationMap.length(); i++) {
		if (_cioDestinationMap[i] != -1) {
			retVal++;
		}
	}

	return retVal;
}
