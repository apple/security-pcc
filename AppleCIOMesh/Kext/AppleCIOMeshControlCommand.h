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

#include "Common/Config.h"
#include "Util/SymbolWorkaround.h"

#include <IOKit/IOCommandPool.h>
#include <IOKit/IOService.h>
#include <IOKit/IOWorkLoop.h>
#include <IOKit/platform/AppleARMIODevice.h>
#include <IOKit/thunderbolt/AppleThunderboltGenericHAL.h>
#include <IOKit/thunderbolt/IOThunderboltReceiveCommand.h>
#include <IOKit/thunderbolt/IOThunderboltTransmitCommand.h>
#include <libkern/c++/OSObject.h>

#include "AppleCIOMeshHardwarePlatform.h"
#include "AppleCIOMeshUserClientInterface.h"

namespace MUCI  = AppleCIOMeshUserClientInterface;
namespace MCUCI = AppleCIOMeshConfigUserClientInterface;

class AppleCIOMeshControlPath;
struct MeshControlCommand;
struct MeshControlMessage;

// MARK: - Base Control Commands

class AppleCIOMeshReceiveControlCommand : public IOThunderboltReceiveCommand
{
	OSDeclareDefaultStructors(AppleCIOMeshReceiveControlCommand);
	using super = IOThunderboltReceiveCommand;

  public:
	static AppleCIOMeshReceiveControlCommand * allocate(AppleCIOMeshControlPath * path);
	bool init(AppleCIOMeshControlPath * link, IOBufferMemoryDescriptor * md);
	void free() APPLE_KEXT_OVERRIDE final;
	MeshControlCommand * getCommand();
	MeshControlMessage * getControlMessage();
	AppleCIOMeshControlPath * getControlPath();

  private:
	void * _addr;
	AppleCIOMeshControlPath * _path;
};

class AppleCIOMeshTransmitControlCommand : public IOThunderboltTransmitCommand
{
	OSDeclareDefaultStructors(AppleCIOMeshTransmitControlCommand);
	using super = IOThunderboltTransmitCommand;

  public:
	static AppleCIOMeshTransmitControlCommand * allocate(AppleCIOMeshControlPath * path);
	bool init(AppleCIOMeshControlPath * link, IOBufferMemoryDescriptor * md);
	void free() APPLE_KEXT_OVERRIDE final;
	MeshControlCommand * getCommand();

  private:
	void * _addr;
	AppleCIOMeshControlPath * _path;
};

// MARK: - Control Commands

enum class MeshControlCommandType : uint32_t {
	RawMessage = 0x0,
	// Request Command for node identification of the CIO Link partner.
	NodeIdentificationRequest = 0x1,
	// Node identification response (to node identification request).
	NodeIdentificationResponse,
	// Link identification to let the CIO partner know which link is
	// which index. This is important for the channel principal to
	// make sure both nodes have the links in the same order.
	LinkIdentification,
	// Command from the channel principal to let the agent know
	// the links are in the right order.
	ChannelReady,
	// Channel principal got link identifications that are not in the
	// same order as it, so it requests the agent to swap.
	ChannelLinkSwap,
	// Channel principal sends a PING on the primary control link.
	PrimaryLinkPing,
	// Channel agent send a PONG on the secondary control link.
	SecondaryLinkPong,
	// A TX assignment is made for data from SourceNode on the
	// Mesh channel (mesh link path technically). The receiver
	// should setup a RX path on the same mesh channel.
	TxAssignmentNotification,
	// Used to notify the source node, the forwarder is sending
	// its data to the receiver.
	TxForwardNotificationCommand,
	// Used to notify a new generation in the mesh has begun.
	NewGeneration,
	MaxMeshControlCommandType,
};

typedef struct NodeIdentificationRequestCommand {
} __attribute__((packed)) NodeIdentificationRequestCommand;

typedef struct NodeIdentificationResponseCommand {
	MCUCI::NodeId configNodeId;
	MCUCI::ChassisId chassisId;
	HardwareNodeId hardwareNodeId;
} __attribute__((packed)) NodeIdentificationResponseCommand;

typedef struct LinkIdentificationCommand {
	MCUCI::NodeId nodeId;
	uint8_t linkIdx;
} __attribute__((packed)) LinkIdentificationCommand;

typedef struct ChannelReadyCommand {
	MCUCI::NodeId nodeIdA;
	MCUCI::NodeId nodeIdB;
} __attribute__((packed)) ChannelReadyCommand;

typedef struct TxAssignmentNotificationCommand {
	MCUCI::NodeId sourceNodeId;
	uint32_t pathIndex;
} TxAssignmentNotificationCommand;

typedef struct TxForwardNotificationCommand {
	MCUCI::NodeId sourceNode;
	MCUCI::NodeId forwarder;
	MCUCI::NodeId receiver;
} TxForwardNotificationCommand;

typedef struct ControlMessageHeader {
	MCUCI::NodeId sourceNode;
	MCUCI::NodeId destinationNode;
	uint32_t length;
} ControlMessageHeader;

typedef struct StartGenerationCommand {
	MCUCI::NodeId sourceNode;
	MCUCI::NodeId destinationNode;
	uint32_t generation;
} StartGenerationCommand;

typedef union MeshControlCommandData {
	uint8_t raw_data[kCommandDataSize];
	NodeIdentificationRequestCommand nodeIdRequest;
	NodeIdentificationResponseCommand nodeIdResponse;
	LinkIdentificationCommand linkId;
	ChannelReadyCommand channelReady;
	TxAssignmentNotificationCommand txAssignment;
	TxForwardNotificationCommand txForward;
	ControlMessageHeader controlMessage;
	StartGenerationCommand startGeneration;
} __attribute__((packed)) MeshControlCommandData;

typedef struct MeshControlCommand {
	MeshControlCommandType commandType;
	MeshControlCommandData data;
} __attribute__((packed)) MeshControlCommand;

typedef struct MeshControlMessage {
	MeshControlCommand header;
	uint8_t data[kCommandMessageDataSize];
} __attribute__((packed)) MeshControlMessage;

static_assert(sizeof(MeshControlCommand) == kCommandSize, "MeshControlCommand not cache aligned");
static_assert(sizeof(MeshControlMessage) == kCommandBufferSize, "MeshControlMessage not full buffer space");
