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

//
//  UserClientConfig.cpp
//  AppleVirtMesh
//
//  Created by Zixuan Wang on 11/19/24.
//

#include "VirtMesh/Guest/AppleVirtMesh/UserClientConfig.h"
#include "VirtMesh/Guest/AppleVirtMesh/Common.h"
#include "VirtMesh/Guest/AppleVirtMesh/Driver.h"
#include <IOKit/IOUserClient.h>

using namespace VirtMesh::Guest::UserClient;
using namespace VirtMesh::Guest::Mesh;
using namespace VirtMesh::Guest::Mesh::ConfigClient;

OSDefineMetaClassAndStructors(AppleVirtMeshConfigUserClient, super);

/** @todo: The condig client does not check for entitlement for now,
 *         consider checking it to match the CIOMesh config kext's behavior.
 */
#define DEFINE_METHOD(selector, method, input_size, output_size, allow_async)                                    \
	[ConfigClient::Methods::selector] = {                                                                        \
	    .function                 = static_cast<IOExternalMethodAction>(&AppleVirtMeshConfigUserClient::method), \
	    .checkScalarInputCount    = 0,                                                                           \
	    .checkStructureInputSize  = input_size,                                                                  \
	    .checkScalarOutputCount   = 0,                                                                           \
	    .checkStructureOutputSize = output_size,                                                                 \
	    .allowAsync               = allow_async,                                                                 \
	    .checkEntitlement         = nullptr,                                                                     \
	}

/* clang-format off */
const IOExternalMethodDispatch2022 AppleVirtMeshConfigUserClient::sExternalMethodDispatchTable[ConfigClient::Methods::TotalMethods] = {
    DEFINE_METHOD(NotificationRegister,   notification_register         , 0                          , 0                      , true ),
    DEFINE_METHOD(NotificationUnregister, notification_unregister       , 0                          , 0                      , false),
    DEFINE_METHOD(GetHardwareState,       get_hardware_state            , 0                          , sizeof(HardwareState)  , false),
    DEFINE_METHOD(SetExtendedNodeId,      set_node_id                   , sizeof(NodeId)             , 0                      , false),
    DEFINE_METHOD(GetExtendedNodeId,      get_extended_node_id          , 0                          , sizeof(NodeId)         , false),
    DEFINE_METHOD(GetLocalNodeId,         get_node_id                   , 0                          , sizeof(NodeId)         , false),
    DEFINE_METHOD(SetChassisId,           set_chassis_id                , sizeof(ChassisId)          , 0                      , false),
    DEFINE_METHOD(AddPeerHostname ,       set_peer_hostnames            , sizeof(PeerNode)           , 0                      , false),
    DEFINE_METHOD(GetPeerHostnames ,      get_peer_hostnames            , 0                          , sizeof(PeerHostnames)  , false),
    DEFINE_METHOD(Activate,               activate                      , 0                          , 0                      , false),
    DEFINE_METHOD(Deactivate,             deactivate                    , 0                          , 0                      , false),
    DEFINE_METHOD(Lock,                   lock                          , 0                          , 0                      , false),
    DEFINE_METHOD(IsLocked,               is_locked                     , 0                          , 0                      , false),
    DEFINE_METHOD(DisconnectCIOChannel,   disconnect_cio_channel        , sizeof(MeshChannelIdx)     , 0                      , false),
    DEFINE_METHOD(EstablishTxConnection,  establish_tx_connection       , sizeof(NodeConnectionInfo) , 0                      , false),
    DEFINE_METHOD(SendControlMessage,     send_control_message          , sizeof(MeshMessage)        , 0                      , false),
    DEFINE_METHOD(GetConnectedNodes,      get_connected_nodes           , 0                          , sizeof(ConnectedNodes) , false),
    DEFINE_METHOD(GetCIOConnectionState,  get_cio_connections           , 0                          , sizeof(CIOConnections) , false),
    DEFINE_METHOD(SetCryptoKey,           set_crypto_state              , sizeof(CryptoInfo)         , 0                      , false),
    DEFINE_METHOD(GetCryptoKey,           get_crypto_state              , sizeof(CryptoInfo)         , sizeof(CryptoInfo)     , false),
    DEFINE_METHOD(GetBuffersUsedByKey,    get_buffers_allocated         , 0                          , sizeof(uint64_t)       , false),
    DEFINE_METHOD(CanActivate,            can_activate                  , sizeof(MeshNodeCount)      , 0                      , false),
    DEFINE_METHOD(SetEnsembleSize,        set_ensemble_size             , sizeof(EnsembleSize)       , 0                      , false),
    DEFINE_METHOD(GetEnsembleSize,        get_ensemble_size             , sizeof(EnsembleSize)       , sizeof(EnsembleSize)   , false),
};
/* clang-format on */

/* Functions for setting up environments in IOKit interface handlers */

static inline AppleVirtMeshConfigUserClient *
cast_to_client(OSObject * target)
{
	return OSRequiredCast(AppleVirtMeshConfigUserClient, target);
}

enum class MeshEnsure : uint8_t {
	Skip = 0,
	AlreadyLocked, /* Ensure CIO is locked, return error if not. */
	NotLocked,     /* Ensure CIO is not yet locked, return error if locked. */
};

template <typename Func>
concept ClientHandler = requires(Func f, AppleVirtMeshConfigUserClient * client, AppleVirtMeshDriver * driver) {
	{ f(client, driver) };
};

template <ClientHandler Func>
[[nodiscard]] static inline IOReturn
with_client(OSObject * target, MeshEnsure ensure, Func func)
{
	auto client = cast_to_client(target);

	switch (ensure) {
	case MeshEnsure::Skip:
		break;
	case MeshEnsure::AlreadyLocked:
		if (!client->_driver->get_cio_locked()) {
			os_log_error(client->_logger, "CIO not locked, cannot proceed");
			return kIOReturnBusy;
		}
		break;

	case MeshEnsure::NotLocked:
		if (client->_driver->get_cio_locked()) {
			os_log_error(client->_logger, "CIO locked, cannot proceed");
			return kIOReturnBusy;
		}
		break;
	}

	return func(client, client->_driver);
}

bool
AppleVirtMeshConfigUserClient::start(IOService * provider)
{
	if (!super::start(provider)) {
		os_log_error(_logger, "Super user client class failed to start");
		return false;
	}

	_io_data_queue = IOSharedDataQueue::withEntries(kMaxMessageCount, sizeof(MeshMessage));
	if (nullptr == _io_data_queue) {
		os_log_error(_logger, "Failed to construct data queue");
		return false;
	}

	if (!_driver->register_config_user_client(this)) {
		os_log_error(_logger, "Failed to register config user client");
		return false;
	}

	return true;
}

void
AppleVirtMeshConfigUserClient::stop(IOService * provider)
{
	_driver->unregister_config_user_client(this);
	super::stop(provider);
}

IOReturn
AppleVirtMeshConfigUserClient::externalMethod(uint32_t selector, IOExternalMethodArgumentsOpaque * args)
{
	auto arg = (IOExternalMethodArguments *)args;
	DEV_LOG(
	    _logger,
	    "Config client externalMethod: selector [%u] StructureInputSize [%u], StructureOutputSize = [%u]",
	    selector,
	    arg->structureInputSize,
	    arg->structureOutputSize
	);
	return dispatchExternalMethod(selector, args, sExternalMethodDispatchTable, ConfigClient::Methods::TotalMethods, this, nullptr);
}

IOReturn
AppleVirtMeshConfigUserClient::registerNotificationPort(mach_port_t port, UInt32, UInt32)
{
	_io_data_queue->setNotificationPort(port);
	return kIOReturnSuccess;
}

IOReturn
AppleVirtMeshConfigUserClient::clientMemoryForType(
    UInt32                type [[maybe_unused]],
    IOOptionBits *        options [[maybe_unused]],
    IOMemoryDescriptor ** memory
)
{
	*memory = _io_data_queue->getMemoryDescriptor().detach();
	(*memory)->retain();

	return kIOReturnSuccess;
}

/**
 * @todo: this is duplicated with main kext, move them into the base client
 */
IOReturn
AppleVirtMeshConfigUserClient::notification_register(
    OSObject *                  target,
    void *                      ref [[maybe_unused]],
    IOExternalMethodArguments * args
)
{
	return with_client(target, MeshEnsure::Skip, [&](auto client, auto) {
		DEV_LOG(_logger, "Registering notification");

		if (MACH_PORT_NULL == args->asyncWakePort) {
			os_log_error(_logger, "Got an invalid wake port: %016llx", (uint64_t)args->asyncWakePort);
			return kIOReturnBadArgument;
		}

		{
			IOLockGuard guard(client->_notify.lock);

			if (client->_notify.ref_valid) {
				/* Zixuan's understanding: This is to de-register pre-existing notify reference, if any. Although I don't think it
				 * would be the case, probably the original CIOMesh kext ran into some issue and implemented this.
				 */
				releaseAsyncReference64(client->_notify.ref);
			}
			memcpy(client->_notify.ref, args->asyncReference, sizeof(client->_notify.ref));
			client->_notify.ref_valid = true;
		}

		return kIOReturnSuccess;
	});
}

IOReturn
AppleVirtMeshConfigUserClient::notification_unregister(
    OSObject *                  target,
    void *                      ref [[maybe_unused]],
    IOExternalMethodArguments * args [[maybe_unused]]
)
{
	return with_client(target, MeshEnsure::Skip, [&](auto client, auto) {
		IOLockGuard guard(client->_notify.lock);

		DEV_LOG(_logger, "Unregistering notification");

		if (!client->_notify.ref_valid) {
			os_log_error(_logger, "Notification ref is invalid.");
			return kIOReturnBadArgument;
		}

		releaseAsyncReference64(client->_notify.ref);
		client->_notify.ref_valid = false;

		return kIOReturnSuccess;
	});
}

void
AppleVirtMeshConfigUserClient::notify_channel_change(const MeshChannelInfo & channel_info, bool available)
{
	io_user_reference_t notify_type = static_cast<io_user_reference_t>(Notification::MeshChannelChange);
	constexpr uint64_t  notify_size = fold_size<io_user_reference_t, MeshChannelInfo, bool>(sizeof(io_user_reference_t));
	uint8_t             buffer[notify_size];

	auto res = fold_all(buffer, notify_size, notify_type, channel_info, available);
	if (!res) {
		os_log_error(_logger, "Failed to prepare channel change response.");
		return;
	}

	notify_send(reinterpret_cast<io_user_reference_t *>(buffer), notify_size / sizeof(io_user_reference_t));
}

void
AppleVirtMeshConfigUserClient::notify_connection_change(const NodeConnectionInfo & connection_info, bool connected, bool TX)
{
	io_user_reference_t notify_type = TX ? static_cast<io_user_reference_t>(Notification::TXNodeConnectionChange)
	                                     : static_cast<io_user_reference_t>(Notification::RXNodeConnectionChange);
	constexpr uint64_t  notify_size = fold_size<io_user_reference_t, NodeConnectionInfo, bool>(sizeof(io_user_reference_t));
	uint8_t             buffer[notify_size];

	auto res = fold_all(buffer, notify_size, notify_type, connection_info, connected);
	if (!res) {
		os_log_error(_logger, "Failed to prepare connection change response.");
		return;
	}

	notify_send(reinterpret_cast<io_user_reference_t *>(buffer), notify_size / sizeof(io_user_reference_t));
}

void
AppleVirtMeshConfigUserClient::notify_control_message(const MeshMessage * message)
{
	DEV_LOG(_logger, "Got an incoming control message, returning it to the user");
	_io_data_queue->enqueue((void *)message, sizeof(MeshMessage));
}

IOReturn
AppleVirtMeshConfigUserClient::set_crypto_state(OSObject * target, void * ref [[maybe_unused]], IOExternalMethodArguments * args)
{
	return with_client(target, MeshEnsure::Skip, [&](auto, auto driver) {
		auto input_arg    = UserClient::EMAInputExtractor<CryptoInfo>(args);
		auto input_crypto = reinterpret_cast<const CryptoInfo *>(input_arg.get());

		/**
		 * @todo: Check for entitlement as AppleCIOMesh/Kext/AppleCIOMeshConfigUserClient.cpp:setCryptoState
		 */

		if (input_crypto->keyDataLen != kUserKeySize) {
			os_log_error(
			    _logger,
			    "Input crypto length [%zu] does not match the user key size [%zu]",
			    input_crypto->keyDataLen,
			    kUserKeySize
			);
			return kIOReturnBadArgument;
		}

		AppleCIOMeshCryptoKey user_key;
		if (0 != copyin((const user_addr_t)input_crypto->keyData, (void *)&user_key.key[0], kUserKeySize)) {
			os_log_error(_logger, "Failed to copy in the crypto data");
			return kIOReturnBadArgument;
		}

		driver->set_user_key(&user_key);
		memset_s(&user_key, sizeof(AppleCIOMeshCryptoKey), 0, sizeof(AppleCIOMeshCryptoKey));

		driver->set_crypto_flags(&input_crypto->flags);

		/**
		 * @todo: need to implement _maxTimePerKey as in AppleCIOMesh/Kext/AppleCIOMeshService.cpp:_cryptoKeyResetUCGated()
		 */
		driver->set_crypto_key_used(false);

		return kIOReturnSuccess;
	});
}

/**
 * @brief: Get the crypto key to the framework
 * @return: the keyDataLen and flags are returned through output_crypto, and the keyData is returned trhough input_crypto
 * @ref: AppleCIOMesh/Kext/AppleCIOMeshConfigUserClient.cpp:getCryptoState()
 */
IOReturn
AppleVirtMeshConfigUserClient::get_crypto_state(OSObject * target, void * ref [[maybe_unused]], IOExternalMethodArguments * args)
{
	return with_client(target, MeshEnsure::Skip, [&](auto, auto driver) {
		auto input_arg    = UserClient::EMAInputExtractor<CryptoInfo>(args);
		auto input_crypto = reinterpret_cast<const CryptoInfo *>(input_arg.get());

		auto output_arg    = UserClient::EMAOutputExtractor<CryptoInfo>(args);
		auto output_crypto = reinterpret_cast<CryptoInfo *>(output_arg.get());

		/**
		 * @todo Need to check for key used or not based on global "gDisableSingleKeyUse"
		 * @ref AppleCIOMesh/Kext/AppleCIOMeshConfigUserClient.cpp:getCryptoState()
		 * @note This check was initially in AppleCIOMesh/Kext/AppleCIOMeshService.cpp:_getUserKeyGated(), I think moving it here is
		 * easier to understand.
		 */

		if (driver->get_crypto_key_used()) {
			os_log_error(_logger, "Failed to get crypto, it's already used or never set");
			return kIOReturnExclusiveAccess;
		}

		AppleCIOMeshCryptoKey user_key;
		auto                  ret = driver->get_user_key(&user_key);
		if (kIOReturnSuccess != ret) {
			os_log_error(_logger, "Failed to get user key");
			return ret;
		}

		if (0 != (copyout((void *)&user_key.key, (user_addr_t)input_crypto->keyData, kUserKeySize))) {
			os_log_error(
			    _logger,
			    "Failed to copy out the key to user space (userKeyLen %zd, keyDataLen %zd)\n",
			    kUserKeySize,
			    input_crypto->keyDataLen
			);
			return kIOReturnBadArgument;
		}

		memset_s(&user_key, sizeof(AppleCIOMeshCryptoKey), 0, sizeof(AppleCIOMeshCryptoKey));

		output_crypto->keyDataLen = kUserKeySize;

		CryptoFlags crypto_flags;
		driver->get_crypto_flags(&crypto_flags);
		output_crypto->flags = crypto_flags;

		/**
		 * @todo: Need to use atomic_strong_compare_and_exchange as
		 * AppleCIOMesh/Kext/AppleCIOMeshService.cpp/_cryptoKeyMarkUsedUCGated()
		 */
		driver->set_crypto_key_used(true);

		return kIOReturnSuccess;
	});
}

IOReturn
AppleVirtMeshConfigUserClient::activate(
    OSObject *                  target,
    void *                      ref [[maybe_unused]],
    IOExternalMethodArguments * args [[maybe_unused]]
)
{
	return with_client(target, MeshEnsure::NotLocked, [&](auto, auto driver) { return driver->activate(); });
}

IOReturn
AppleVirtMeshConfigUserClient::deactivate(
    OSObject *                  target,
    void *                      ref [[maybe_unused]],
    IOExternalMethodArguments * args [[maybe_unused]]
)
{
	return with_client(target, MeshEnsure::Skip, [&](auto, auto driver) {
		if (false == driver->get_active()) {
			DEV_LOG(_logger, "Already deactivated, skipping this deactivation");
			return kIOReturnSuccess;
		}

		driver->set_active(false);

		/**
		 * @todo: revisit this logic, it's from AppleCIOMesh/Kext/AppleCIOMeshService.cpp:_deactivateMeshUCGated()
		 */
		// driver->set_cio_locked(false);

		driver->set_was_deactivated(true);

		return kIOReturnSuccess;
	});
}

IOReturn
AppleVirtMeshConfigUserClient::get_hardware_state(OSObject * target, void * ref [[maybe_unused]], IOExternalMethodArguments * args)
{
	return with_client(target, MeshEnsure::Skip, [&](auto, auto) {
		auto output_arg      = UserClient::EMAOutputExtractor<HardwareState>(args);
		auto output_hw_state = reinterpret_cast<HardwareState *>(output_arg.get());

		output_hw_state->meshLinksPerChannel = kVREMeshLinksPerChannel;
		output_hw_state->meshChannelCount    = kVREMeshChannelCount;
		output_hw_state->meshLinkCount       = kVREMeshLinkCount;
		output_hw_state->maxMeshChannelCount = kMaxMeshChannelCount;
		output_hw_state->maxMeshLinkCount    = kMaxMeshLinkCount;

		return kIOReturnSuccess;
	});
}

IOReturn
AppleVirtMeshConfigUserClient::lock(
    OSObject *                  target,
    void *                      ref [[maybe_unused]],
    IOExternalMethodArguments * args [[maybe_unused]]
)
{
	return with_client(target, MeshEnsure::NotLocked, [&](auto, auto driver) {
		driver->set_cio_locked(true);
		return kIOReturnSuccess;
	});
}

IOReturn
AppleVirtMeshConfigUserClient::is_locked(
    OSObject *                  target,
    void *                      ref [[maybe_unused]],
    IOExternalMethodArguments * args [[maybe_unused]]
)
{
	return with_client(target, MeshEnsure::Skip, [&](auto, auto driver) {
		if (driver->get_cio_locked()) {
			return kIOReturnSuccess;
		}

		os_log_info(_logger, "CIO is not locked");
		return kIOReturnNotReady;
	});
}

IOReturn
AppleVirtMeshConfigUserClient::disconnect_cio_channel(
    OSObject *                  target,
    void *                      ref [[maybe_unused]],
    IOExternalMethodArguments * args [[maybe_unused]]
)
{
	return with_client(target, MeshEnsure::NotLocked, [&](auto, auto) {
		/**
		 * @todo: need to implement
		 */
		DEV_LOG(_logger, "disconnect_cio_channel() is not yet implemented, it always returns success");
		return kIOReturnSuccess;
	});
}

IOReturn
AppleVirtMeshConfigUserClient::can_activate(OSObject * target, void * ref [[maybe_unused]], IOExternalMethodArguments * args)
{
	return with_client(target, MeshEnsure::Skip, [&](auto, auto) {
		auto node_count = UserClient::EMAInputExtractor<MeshNodeCount>(args);
		if (2 != *node_count.get()) {
			os_log_error(_logger, "can_activate() only supports two nodes, but got %d", *node_count.get());
			return kIOReturnUnsupported;
		}

		/* TODO: the CIOMesh kext tests if mesh links are ready to activate, while VirtMesh just blindly return success. I don't
		 * think this will cause any issue, but needs further testing with ensembleconfig.
		 */
		return kIOReturnSuccess;
	});
}

IOReturn
AppleVirtMeshConfigUserClient::send_control_message(
    OSObject *                  target,
    void *                      ref [[maybe_unused]],
    IOExternalMethodArguments * args
)
{
	return with_client(target, MeshEnsure::Skip, [&](auto, auto driver) {
		auto control_message = UserClient::EMAInputExtractor<MeshMessage>(args);
		return driver->send_control_message(control_message.get());
	});
}

IOReturn
AppleVirtMeshConfigUserClient::get_extended_node_id(
    OSObject *                  target,
    void *                      ref [[maybe_unused]],
    IOExternalMethodArguments * args
)
{
	return with_client(target, MeshEnsure::Skip, [&](auto, auto driver) {
		auto extended_node_id_output = UserClient::EMAOutputExtractor<NodeId>(args);
		auto output                  = reinterpret_cast<NodeId *>(extended_node_id_output.get());
		if (auto res = driver->get_node_id(output); kIOReturnSuccess != res) {
			os_log_error(_logger, "Failed to get extended node id");
			return res;
		}

		/* Only assume one partition in VRE, no actual extended node */
		unsigned curr_partition_idx = 0;
		output->id                  = curr_partition_idx * 8 + output->id;

		return kIOReturnSuccess;
	});
}

/**
 * @brief Getters and setters for properties that follows a simple get/set procedure.
 */
#define SET_PROPERTY(prop_type, prop_name, ensure)                                          \
	IOReturn AppleVirtMeshConfigUserClient::set_##prop_name(                                \
	    OSObject *                  target,                                                 \
	    void *                      ref [[maybe_unused]],                                   \
	    IOExternalMethodArguments * args                                                    \
	)                                                                                       \
	{                                                                                       \
		return with_client(target, ensure, [&](auto client [[maybe_unused]], auto driver) { \
			auto prop_name##_input = UserClient::EMAInputExtractor<prop_type>(args);        \
			return driver->set_##prop_name(prop_name##_input.get());                        \
		});                                                                                 \
	}

#define GET_PROPERTY(prop_type, prop_name, ensure)                                                   \
	IOReturn AppleVirtMeshConfigUserClient::get_##prop_name(                                         \
	    OSObject *                  target,                                                          \
	    void *                      ref [[maybe_unused]],                                            \
	    IOExternalMethodArguments * args                                                             \
	)                                                                                                \
	{                                                                                                \
		return with_client(target, ensure, [&](auto client [[maybe_unused]], auto driver) {          \
			auto prop_name##_output       = UserClient::EMAOutputExtractor<prop_type>(args);         \
			auto prop_name##_output_typed = reinterpret_cast<prop_type *>(prop_name##_output.get()); \
			return driver->get_##prop_name(prop_name##_output_typed);                                \
		});                                                                                          \
	}

/**
 * @brief Define getter and setter functions.
 */

/* clang-format off */
GET_PROPERTY(NodeId            , node_id           , MeshEnsure::AlreadyLocked );
GET_PROPERTY(uint64_t          , buffers_allocated , MeshEnsure::Skip          );
GET_PROPERTY(CIOConnections    , cio_connections   , MeshEnsure::Skip          );
GET_PROPERTY(ConnectedNodes    , connected_nodes   , MeshEnsure::AlreadyLocked );
GET_PROPERTY(PeerHostnames     , peer_hostnames    , MeshEnsure::AlreadyLocked );
GET_PROPERTY(EnsembleSize      , ensemble_size     , MeshEnsure::AlreadyLocked );

SET_PROPERTY(NodeId            , node_id           , MeshEnsure::NotLocked     );
SET_PROPERTY(ChassisId         , chassis_id        , MeshEnsure::NotLocked     );
SET_PROPERTY(PeerNode          , peer_hostnames    , MeshEnsure::NotLocked     );
SET_PROPERTY(EnsembleSize      , ensemble_size     , MeshEnsure::NotLocked     );
/* clang-format on */
