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

#include "AppleCIOMeshHardwarePlatform.h"

void
AppleCIOMeshPartnerMap::populate(AppleCIOMeshHardwareConfig * hardwareConfig, HardwareNodeId nodeId)
{
	if (nodeId >= hardwareConfig->numNodes) {
		panic("NodeId %d is larger than nodes in hardware config: %d", nodeId, hardwareConfig->numNodes);
	}

	for (int i = 0; i < kMaxMeshLinkCount; i++) {
		hardwareNodes[i] = hardwareConfig->nodePartners[nodeId].hardwareNodes[i];
	}

	initialized         = true;
	currentHardwareNode = nodeId;
}

/*
 * 'A' cables connect externally to another chassis.
 * 'B' cables connect externally to nodes _within_ the same chassis (see a picture for actual J236).
 * 'internal' cables are on the circuit board.
 * Each cable provides two links.
 *
 *                  ┌─────────┐                ┌─────────┐
 *                  │         │                │         │
 * ┌─────────────0A─┼ Node 0  │                │ Node 1  │
 * │                │         ┼───internal─────┤         ┼─1A───────────────────────┐
 * │                │         │                │         │                          │
 * │                └────┬────┤   ┌─────────1B─┴────┬────┘                          │
 * │                     │    0B  │                 │                               │
 * │                     │    │   │                 │                               │
 * │                     │    └───┼─────────────┐   │                               │
 * │                 internal     ┼             │  internal                         │
 * │                     │        │             │   │                               │
 * │                     │        │             │   │                               │
 * │                     │        │             3B  │                               │
 * │                ┌────┼────┐   │            ┬┼───┴────┐                          │
 * │                │         │   │            │         │                          │
 * │                │ Node 2  ├─2B┘            │ Node 3  ┼─3A─────────┐             │
 * │         ┌──2A──┤         ├─────internal───┼         │            │             │
 * │         │      │         │                │         │            │             │
 * │         │      └─────────┘                └─────────┘            │             │
 * │         │                                                        │             │
 * │         │                                                        │             │
 * │         │                                                        │             │
 * └─────────┼───────          Other 4-node chassis here        ──────┼─────────────┘
 *           │                                                        │
 *           │                                                        │
 */

void
AppleCIOMeshHardwareConfig::populate(uint8_t meshConfiguration)
{
	if (meshConfiguration == kJ236Hypercube) {
		numNodes = 4;

		// Node 0
		nodePartners[0].hardwareNodes[0] = 3; // B
		nodePartners[0].hardwareNodes[1] = 0; // A
		nodePartners[0].hardwareNodes[2] = 3; // B
		nodePartners[0].hardwareNodes[3] = 0; // A
		nodePartners[0].hardwareNodes[4] = 1; // internal
		nodePartners[0].hardwareNodes[5] = 2; // internal
		nodePartners[0].hardwareNodes[6] = 2; // internal
		nodePartners[0].hardwareNodes[7] = 1; // internal

		// Node 1
		nodePartners[1].hardwareNodes[0] = 2; // B
		nodePartners[1].hardwareNodes[1] = 1; // A
		nodePartners[1].hardwareNodes[2] = 2; // B
		nodePartners[1].hardwareNodes[3] = 1; // A
		nodePartners[1].hardwareNodes[4] = 0; // internal
		nodePartners[1].hardwareNodes[5] = 3; // internal
		nodePartners[1].hardwareNodes[6] = 3; // internal
		nodePartners[1].hardwareNodes[7] = 0; // internal

		// Node 2
		nodePartners[2].hardwareNodes[0] = 1; // B
		nodePartners[2].hardwareNodes[1] = 2; // A
		nodePartners[2].hardwareNodes[2] = 1; // B
		nodePartners[2].hardwareNodes[3] = 2; // A
		nodePartners[2].hardwareNodes[4] = 3; // internal
		nodePartners[2].hardwareNodes[5] = 0; // internal
		nodePartners[2].hardwareNodes[6] = 0; // internal
		nodePartners[2].hardwareNodes[7] = 3; // internal

		// Node 3
		nodePartners[3].hardwareNodes[0] = 0; // B
		nodePartners[3].hardwareNodes[1] = 3; // A
		nodePartners[3].hardwareNodes[2] = 0; // B
		nodePartners[3].hardwareNodes[3] = 3; // A
		nodePartners[3].hardwareNodes[4] = 2; // internal
		nodePartners[3].hardwareNodes[5] = 1; // internal
		nodePartners[3].hardwareNodes[6] = 1; // internal
		nodePartners[3].hardwareNodes[7] = 2; // internal

		return;
	}

	panic("Unknown mesh configuration: %d", meshConfiguration);
}

const char *
AppleCIOMeshHardwareConfig::getLinkLabel(HardwareNodeId nodeId, uint8_t linkId)
{
	if (nodeId >= numNodes) {
		panic("NodeId %d is larger than nodes in hardware config: %d", nodeId, numNodes);
	}

	const auto maxLinkCount = numNodes * 2;

	if (linkId >= maxLinkCount) {
		panic("linkId %d is larger than the number of possible links in hardware config: %d", linkId, maxLinkCount);
	}

	if (nodeId == linkId) {
		// 0A on one chassis will be connected to 0A on the other chassis.
		// 1A on one chassis will be connected to 1A on the other chassis.
		// etc.
		// See the diagram at the top of this file.
		return "A";
	}

	if (linkId == nodePartners[nodeId].hardwareNodes[0] || linkId == nodePartners[nodeId].hardwareNodes[2]) {
		return "B";
	}

	return "Internal";
}
