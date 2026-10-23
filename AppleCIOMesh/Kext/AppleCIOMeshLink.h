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

#include <IOKit/IOCommandPool.h>
#include <IOKit/IOService.h>
#include <IOKit/IOWorkLoop.h>
#include <IOKit/platform/AppleARMIODevice.h>
#include <IOKit/thunderbolt/AppleThunderboltGenericHAL.h>
#include <IOKit/thunderbolt/IOThunderboltCommandGate.h>
#include <IOKit/thunderbolt/IOThunderboltController.h>
#include <IOKit/thunderbolt/IOThunderboltPath.h>
#include <IOKit/thunderbolt/IOThunderboltXDomainLink.h>
#include <libkern/c++/OSBoundedArray.h>

#include "AppleCIOMeshControlCommand.h"
#include "AppleCIOMeshUserClientInterface.h"

class AppleCIOMeshChannel;
class AppleCIOMeshControlPath;
class AppleCIOMeshRxPath;
class AppleCIOMeshTxPath;
class AppleCIOMeshService;
class AppleCIOMeshSharedMemory;
class AppleCIOMeshTransmitCommand;

namespace MUCI  = AppleCIOMeshUserClientInterface;
namespace MCUCI = AppleCIOMeshConfigUserClientInterface;

class AppleCIOMeshLink : public IOService
{
	OSDeclareDefaultStructors(AppleCIOMeshLink);
	using super = IOService;

  public:
	IOService * probe(IOService *, SInt32 * score) APPLE_KEXT_OVERRIDE final;
	bool start(IOService *) APPLE_KEXT_OVERRIDE final;
	void stop(IOService * provider) APPLE_KEXT_OVERRIDE final;
	bool willTerminate(IOService *, IOOptionBits) APPLE_KEXT_OVERRIDE final;
	bool didTerminate(IOService *, IOOptionBits, bool * defer) APPLE_KEXT_OVERRIDE final;
	void free() APPLE_KEXT_OVERRIDE final;

	void meshServiceInitialized();
	void restartDataPath();
	void startDataPath();
	void stopDataPath();

	uint8_t getRID();
	uint8_t getLinkIdx();
	IOThunderboltController * getController();
	IOThunderboltXDomainLink * getXDLink();
	AppleCIOMeshService * getService();
	IOWorkLoop * getServiceWorkloop();
	AppleCIOMeshControlPath * getControlPath();
	MCUCI::NodeId getConnectedNodeId();
	AppleCIOMeshChannel * getChannel();
	void getChassisId(MCUCI::ChassisId * chassis);
	bool hasPendingLinkId();
	bool getPendingLinkId(LinkIdentificationCommand * cmd);
	bool isMismatchedHardwarePartner();
	void setMismatchedHardwareParther(bool mismatch);
	HardwareNodeId getConnectedHardwareNodeId();
	void setConnectedHardwareNodeId(HardwareNodeId node);

	bool hasConnectedNodeId();

	void setConnectedNodeId(MCUCI::NodeId node);
	void setConnectedChassisId(MCUCI::ChassisId chassis);
	void setChannel(AppleCIOMeshChannel * channel);
	void setPendingLinkId(LinkIdentificationCommand * command);

	uint32_t assignRxNode(MCUCI::NodeId node);
	uint32_t assignTxNode(MCUCI::NodeId node);

	uint32_t getTxPathAssignment(MCUCI::NodeId node);
	uint32_t getRxPathAssignment(MCUCI::NodeId node);

	IOThunderboltReceiveQueue * getRXQueue(MCUCI::NodeId node);
	IOThunderboltTransmitQueue * getTXQueue(MCUCI::NodeId node);

	IOReturn sendData(MCUCI::NodeId node, int64_t offset, IOThunderboltTransmitCommand * transmitCommand = nullptr);

	void prepareTXCommand(MCUCI::NodeId node, IOThunderboltTransmitCommand * command);
	void prepareRXCommand(MCUCI::NodeId node, IOThunderboltReceiveCommand * command);
	void sendPreparedRXCommand(MCUCI::NodeId node);
	// Setup is closer to a pre-prepare step. This does not exist for RX because
	// there is no need to pre-queue and immediately receive. Receive side should
	// be blocking waiting for data. On TX, we setup, then prepare by submitting
	// into the NHI ring and then at the very last minute submit. Only 1 chunk
	// should be prepared at a time (per link), but all chunks should be setup.
	void setupTXBuffer(MCUCI::NodeId node, AppleCIOMeshTransmitCommand * command, AppleCIOMeshSharedMemory * memory);

	void checkDataRXCompletion();
	void checkDataRXCompletionForNode(MCUCI::NodeId node);
	void checkDataTXCompletion();

  private:
	bool _serviceRegistered(void * refCon, IOService * newService, IONotifier * notifier);
	bool _setService(AppleCIOMeshService * service);

	void _startControlPath();
	void _startRegistrationSequence();
	void _registrationHandler(IOTimerEventSource * sender);

	AppleCIOMeshService * _meshService;
	OSBoundedArray<AppleCIOMeshRxPath *, kNumDataPaths> _rxDataPaths;
	OSBoundedArray<AppleCIOMeshTxPath *, kNumDataPaths> _txDataPaths;
	AppleCIOMeshControlPath * _controlPath;

	IOThunderboltController * _tbtController;
	IOThunderboltXDomainLink * _xdLink;
	MCUCI::NodeId _connectedNode;
	bool _hasConnectedNode;
	MCUCI::ChassisId _connectedChassis;

	_Atomic(bool) _rxDescriptorsAccess;

	_Atomic(bool) _txReserved;

	AppleCIOMeshChannel * _channel;

	LinkIdentificationCommand _pendingLinkId;
	bool _hasPendingLinkId;
	bool _registered;
	IONotifier * _meshServiceNotifier;

	enum class RegistrationState : uint8_t {
		Initialized = 0x1,
		WaitingForInitializationComplete,
		ControlPathStarting,
		ControlPathStarted,
		ControlPathQuiesce,
		RegistrationStarting,
		RegistrationStarted,
		PartnerIdentified,
		RegistrationStateCount,
	};

	RegistrationState _registrationState;
	IOTimerEventSource * _registrationEventSource;

	uint8_t _rid;

	// Whether this link is mismatched from the expected hardware
	// partner. If it is, this link is held in limbo indefinitely.
	bool _mismatchedHardwarePartner;
	HardwareNodeId _connectedHardwareNode;
};
