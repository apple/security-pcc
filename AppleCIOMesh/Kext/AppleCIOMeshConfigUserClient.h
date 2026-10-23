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
#include <IOKit/IOSharedDataQueue.h>
#include <IOKit/IOUserClient.h>

namespace MCUCI = AppleCIOMeshConfigUserClientInterface;

class AppleCIOMeshService;

#define kAppleCIOMeshConfigUserAccessEntitlement "com.apple.private.appleciomesh.config-access"
#define kAppleCIOMeshConfigClearCryptoKey "com.apple.private.appleciomesh.clear-crypto-key"
#define kAppleCIOMeshConfigSetCryptoKey "com.apple.private.appleciomesh.set-crypto-key"
#define kAppleCIOMeshConfigUserModifyEntitlement "com.apple.private.appleciomesh.config-modify-access"

class AppleCIOMeshConfigUserClient final : public IOUserClient2022
{
	OSDeclareDefaultStructors(AppleCIOMeshConfigUserClient);
	using super = IOUserClient2022;

  public:
	virtual bool
	initWithTask(task_t owning_task, void * security_token, UInt32 type, OSDictionary * properties) APPLE_KEXT_OVERRIDE;

	virtual bool start(IOService * provider) APPLE_KEXT_OVERRIDE;
	virtual void stop(IOService * provider) APPLE_KEXT_OVERRIDE;
	virtual void free() APPLE_KEXT_OVERRIDE;
	task_t getOwningTask();

	virtual IOReturn clientClose() APPLE_KEXT_OVERRIDE;

	virtual IOReturn externalMethod(uint32_t selector, IOExternalMethodArgumentsOpaque * args) APPLE_KEXT_OVERRIDE;

	virtual IOReturn clientMemoryForType(UInt32 type, IOOptionBits * options, IOMemoryDescriptor ** memory) APPLE_KEXT_OVERRIDE;
	virtual IOReturn registerNotificationPort(mach_port_t, UInt32, UInt32) APPLE_KEXT_OVERRIDE;

	void notifyChannelChange(const MCUCI::MeshChannelInfo & channelInfo, bool available);
	void notifyConnectionChange(const MCUCI::NodeConnectionInfo & connectionInfo, bool connected, bool TX);
	void notifyControlMessage(const MCUCI::MeshMessage * message);

  private:
	void sendNotification(io_user_reference_t * args, uint32_t count);

	// Methods
	static IOReturn notificationRegister(OSObject * target, void * reference, IOExternalMethodArguments * arguments);
	static IOReturn notificationUnregister(OSObject * target, void * reference, IOExternalMethodArguments * arguments);
	static IOReturn getHardwareState(OSObject * target, void * reference, IOExternalMethodArguments * arguments);
	static IOReturn setExtendedNodeId(OSObject * target, void * reference, IOExternalMethodArguments * arguments);
	static IOReturn getExtendedNodeId(OSObject * target, __unused void * reference, IOExternalMethodArguments * arguments);
	static IOReturn getLocalNodeId(OSObject * target, __unused void * reference, IOExternalMethodArguments * arguments);
	static IOReturn setEnsembleSize(OSObject * target, __unused void * reference, IOExternalMethodArguments * arguments);
	static IOReturn getEnsembleSize(OSObject * target, __unused void * reference, IOExternalMethodArguments * arguments);
	static IOReturn setChassisId(OSObject * target, void * reference, IOExternalMethodArguments * arguments);
	static IOReturn addPeerHostname(OSObject * target, void * reference, IOExternalMethodArguments * arguments);
	static IOReturn getPeerHostnames(OSObject * target, void * reference, IOExternalMethodArguments * arguments);
	static IOReturn activate(OSObject * target, void * reference, IOExternalMethodArguments * arguments);
	static IOReturn deactivate(OSObject * target, void * reference, IOExternalMethodArguments * arguments);
	static IOReturn lock(OSObject * target, void * reference, IOExternalMethodArguments * arguments);
	static IOReturn isLocked(OSObject * target, void * reference, IOExternalMethodArguments * arguments);
	static IOReturn disconnectCIOChannel(OSObject * target, void * reference, IOExternalMethodArguments * arguments);
	static IOReturn establishTXConnection(OSObject * target, void * reference, IOExternalMethodArguments * arguments);
	static IOReturn sendControlMessage(OSObject * target, void * reference, IOExternalMethodArguments * arguments);
	static IOReturn getConnectedNodes(OSObject * target, void * reference, IOExternalMethodArguments * arguments);
	static IOReturn getCIOConnectionState(OSObject * target, void * reference, IOExternalMethodArguments * arguments);
	static IOReturn setCryptoState(OSObject * target, void * reference, IOExternalMethodArguments * arguments);
	static IOReturn getCryptoState(OSObject * target, void * reference, IOExternalMethodArguments * arguments);
	static IOReturn getBuffersAllocatedByCrypto(OSObject * target, void * reference, IOExternalMethodArguments * arguments);
	static IOReturn canActivate(OSObject * target, void * reference, IOExternalMethodArguments * arguments);

	bool is_task_entitled_to(task_t task, const char * entitlement);

	static const IOExternalMethodDispatch2022 _methods[MCUCI::Method::NumMethods];
	AppleCIOMeshService * _provider;

	bool _notify_ref_valid;
	OSAsyncReference64 _notify_ref;
	IOLock * _notify_lock;
	task_t _owningTask;
	IOSharedDataQueue * _dataQueue;
};
