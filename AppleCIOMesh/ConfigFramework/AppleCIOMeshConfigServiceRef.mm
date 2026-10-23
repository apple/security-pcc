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

#import <AssertMacros.h>
#import <Foundation/Foundation.h>
#include <IOKit/IODataQueueClient.h>
#import <IOKit/IOKitLib.h>
#import <atomic>
#include <cctype>
#include <mach/mach_error.h>
#import <os/log.h>
#import <string>

#import "AppleCIOMeshConfigUserClientInterface.h"
#import <AppleCIOMeshConfigSupport/AppleCIOMeshConfigServiceRef.h>

#include "Common/Handshake.h"
#include "Common/ScopeGuard.h"
#include "Common/TcpConnection.h"

namespace MCUCI     = AppleCIOMeshConfigUserClientInterface;
namespace MeshUtils = AppleCIOMeshUtils;
namespace MeshNet   = AppleCIOMeshNet;

constexpr auto kPort = 4991;

#define LogDebug(format, args...) os_log_debug(_logger, format, ##args)
#define LogInfo(format, args...) os_log_info(_logger, format, ##args)
#define Log(format, args...) os_log(_logger, format, ##args)
#define LogError(format, args...) os_log_error(_logger, format, ##args)

@implementation AppleCIOMeshConfigServiceRef {
	os_log_t _logger;

	io_service_t _service;
	io_connect_t _connection;

	dispatch_queue_t _queue;
	IONotificationPortRef _notifyPort;

	MeshChannelChangeBlock _meshChannelBlock;
	NodeConnectionChangeBlock _nodeConnectionBlock;
	NodeNetworkConnectionChangeBlock _nodeNetworkConnectionBlock;
	NodeMessageBlock _nodeMessageBlock;

	dispatch_queue_t _dataQueue;
	dispatch_source_t _dataQueueSource;
	mach_port_t _dataQueuePort;
	mach_vm_size_t _dataQueueSize;
	mach_vm_address_t _dataQueueAddr;
	uint64_t _totalDequeueCount;      // running count of all dequeues (not callbacks), for info and debug
	uint64_t _totalNotificationCount; // running count of all notifications (not callbacks), for info and debug
	uint64_t _totalCallbackCount;     // running count of all callbacks, for info and debug
	int _partitionIdx;
	int _nodeId;
	std::atomic<bool> _shuttingDown;
	bool _isExtendedMesh;

	// Single peer info. Needs to be an array for 32n
	std::string _peerHostname;
	uint32_t _peerNodeId;
}

#pragma mark - C functions for IOKit
static void
meshMessageReceived(void * context)
{
	AppleCIOMeshConfigServiceRef * me = (__bridge AppleCIOMeshConfigServiceRef *)context;
	[me meshMessageReceived];
}

static void
notificationReceived(void * refcon, __unused IOReturn result, io_user_reference_t * arg)
{
	AppleCIOMeshConfigServiceRef * me = (__bridge AppleCIOMeshConfigServiceRef *)refcon;

	[me notificationReceived:arg];
}

static uint32_t
toExtendedNodeId(uint32_t nodeId, uint32_t partitionIdx)
{
	assert(partitionIdx >= 0 && partitionIdx < 4);
	return nodeId + (partitionIdx * 8);
}

#pragma mark - Init/deinit

- (instancetype)init
{
	self = [super init];

	if (self != nil) {
		_logger = os_log_create("AppleCIOMeshConfigSupport", "ServiceRef");

		_service       = IO_OBJECT_NULL;
		_connection    = IO_OBJECT_NULL;
		_dataQueuePort = MACH_PORT_NULL;
		_dataQueue     = nil;
		_dataQueueAddr = 0;
		_queue         = nil;
		_notifyPort    = nullptr;

		_meshChannelBlock    = nil;
		_nodeConnectionBlock = nil;
		_nodeMessageBlock    = nil;
	}
	_partitionIdx   = -1;
	_nodeId         = -1;
	_isExtendedMesh = false;

	return self;
}

- (instancetype)initWithIOService:(io_service_t)service
{
	self = [self init];

	if (self != nil) {
		_service = service;
	}

	return self;
}

- (void)dealloc
{
	[self notifyUnregister];
	[self close];
}

+ (instancetype)fromIOService:(io_service_t)service
{
	return [[AppleCIOMeshConfigServiceRef alloc] initWithIOService:service];
}

+ (NSArray<AppleCIOMeshConfigServiceRef *> *)all
{
	auto found = [NSMutableArray<AppleCIOMeshConfigServiceRef *> arrayWithCapacity:1];
	io_iterator_t iter;
	io_object_t obj;

	static const char * services[2] = {MCUCI::matchingName, "AppleVirtMeshDriver"};

	bool succ = false;
	for (auto service : services) {
		if (kIOReturnSuccess == IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(service), &iter)) {
			if (IOIteratorIsValid(iter)) {
				os_log_debug(OS_LOG_DEFAULT, "Connected to service %s", service);
				succ = true;
				break;
			}
		}
	}

	if (!succ) {
		os_log_error(OS_LOG_DEFAULT, "Failed to match any of services");
		return nil;
	}

	while ((obj = IOIteratorNext(iter)) != IO_OBJECT_NULL) {
		[found addObject:[AppleCIOMeshConfigServiceRef fromIOService:obj]];
	}

	IOObjectRelease(iter);
	iter = IO_OBJECT_NULL;

	return found;
}

#pragma mark - User client connection

- (BOOL)isOpen
{
	return _connection != IO_OBJECT_NULL;
}

- (BOOL)open
{
	BOOL success;

	if ([self isOpen])
		return YES;

	success = IOServiceOpen(_service, mach_task_self(), MCUCI::AppleCIOMeshConfigUserClientType, &_connection) == kIOReturnSuccess;

	Log("opening connection: %s", success ? "ok" : "failed");

	if (!success) {
		return success;
	}

	if (_dataQueuePort == MACH_PORT_NULL) {
		_dataQueuePort = IODataQueueAllocateNotificationPort();
	}
	if (_dataQueue == nil) {
		_dataQueue = dispatch_queue_create("cio_mesh_message_queue", DISPATCH_QUEUE_SERIAL);
	}

	kern_return_t res = IOConnectSetNotificationPort(_connection, kIODefaultMemoryType, _dataQueuePort, 0);
	if (kIOReturnSuccess != res) {
		LogError("Failed to set notification port [0x%x]: %s", res, mach_error_string(res));
		return NO;
	}

	res = IOConnectMapMemory(_connection, kIODefaultMemoryType, mach_task_self(), &_dataQueueAddr, &_dataQueueSize, kIOMapAnywhere);
	if (kIOReturnSuccess != res) {
		LogError("Failed to map memory [0x%x]: %s", res, mach_error_string(res));
		return success;
	}

	_dataQueueSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, _dataQueuePort, 0, _dataQueue);
	dispatch_set_context(_dataQueueSource, (__bridge void *)self);
	dispatch_source_set_event_handler_f(_dataQueueSource, meshMessageReceived);
	dispatch_source_set_cancel_handler(_dataQueueSource, ^{
	  mach_port_mod_refs(mach_task_self(), _dataQueuePort, MACH_PORT_RIGHT_RECEIVE, -1);
	  _dataQueuePort = MACH_PORT_NULL;
	});
	dispatch_resume(_dataQueueSource);

	return success;
}

- (void)close
{
	if (![self isOpen])
		return;

	// in case any new messages arrive while we're tearing down this
	// will avoid processing them and racing with tearing down the
	// _dataQueueAddr
	_shuttingDown = true;

	Log("closing connection");
	if (_dataQueuePort != MACH_PORT_NULL) {
		dispatch_source_cancel(_dataQueueSource);
	}
	if (_dataQueueAddr != 0) {
		IOConnectUnmapMemory64(_connection, kIODefaultMemoryType, mach_task_self(), _dataQueueAddr);
		_dataQueueAddr = 0;
	}

	IOServiceClose(_connection);
	_connection = IO_OBJECT_NULL;
}

#pragma mark - Notifications

- (void)setDispatchQueue:(dispatch_queue_t)queue
{
	if (_queue != nil) {
		[self notifyUnregister];
	}
	_queue = queue;
}

- (BOOL)registeredForNotifications
{
	return _notifyPort != nullptr;
}

- (BOOL)notifyRegister
{
	BOOL success;

	io_async_ref64_t asyncRef = {};

	if ([self registeredForNotifications])
		return YES;

	require(_queue != nullptr, fail);

	_notifyPort = IONotificationPortCreate(kIOMainPortDefault);
	require(_notifyPort != nullptr, failNoPort);

	IONotificationPortSetDispatchQueue(_notifyPort, _queue);

	asyncRef[kIOAsyncCalloutFuncIndex]   = reinterpret_cast<uintptr_t>(&notificationReceived);
	asyncRef[kIOAsyncCalloutRefconIndex] = reinterpret_cast<uintptr_t>((__bridge void *)self);

	require([self open], failNoConnect);

	success = IOConnectCallAsyncMethod(_connection, MCUCI::Method::NotificationRegister, IONotificationPortGetMachPort(_notifyPort),
	                                   asyncRef, kIOAsyncCalloutCount, nullptr, 0, nullptr, 0, nullptr, nullptr, nullptr,
	                                   nullptr) == kIOReturnSuccess;
	Log("registering for notifications: %s", success ? "ok" : "failed");
	require(success, failNoConnect);

	return success;

failNoConnect:
	IONotificationPortDestroy(_notifyPort);
	_notifyPort = nullptr;

failNoPort:
fail:
	return NO;
}

- (void)notifyUnregister
{
	if (![self registeredForNotifications])
		return;

	Log("unregistering for notifications");

	if ([self isOpen]) {
		IOConnectCallStructMethod(_connection, MCUCI::Method::NotificationUnregister, nullptr, 0, nullptr, nullptr);
	}

	IONotificationPortDestroy(_notifyPort);
	_notifyPort = nullptr;
}

- (void)notificationReceived:(io_user_reference_t *)args
{
	uint8_t * data = (uint8_t *)args;

	MCUCI::Notification notification = static_cast<MCUCI::Notification>(args[0]);
	uint32_t offset                  = 0;
	offset += sizeof(io_user_reference_t);

	switch (notification) {
	case MCUCI::Notification::MeshChannelChange: {
		MCUCI::MeshChannelInfo * ptrChannelInfo = (MCUCI::MeshChannelInfo *)(data + offset);
		offset += sizeof(MCUCI::MeshChannelInfo);

		uint8_t * ptrConnected = (uint8_t *)(data + offset);
		offset += sizeof(uint8_t);

		__block MCUCI::MeshChannelInfo channelInfo;
		__block bool connected;

		memcpy(&channelInfo, ptrChannelInfo, sizeof(channelInfo));
		memcpy(&connected, ptrConnected, sizeof(connected));

		if (_meshChannelBlock != nil) {
			dispatch_async(_queue, ^{
			  size_t chassisLen  = strnlen(channelInfo.chassis.id, kMaxChassisIdLength);
			  NSString * chassis = [[NSString alloc] initWithBytes:channelInfo.chassis.id
				                                            length:chassisLen
				                                          encoding:NSUTF8StringEncoding];

			  assert(self->_partitionIdx >= 0);
			  auto extendedNodeId = toExtendedNodeId(channelInfo.node, (uint32_t)self->_partitionIdx);
			  self->_meshChannelBlock(channelInfo.channelIndex, extendedNodeId, chassis, connected);
			});
		}
		break;
	}
	case MCUCI::Notification::TXNodeConnectionChange: {
		MCUCI::NodeConnectionInfo * ptrConnectionInfo = (MCUCI::NodeConnectionInfo *)(data + offset);
		offset += sizeof(MCUCI::NodeConnectionInfo);

		uint8_t * ptrConnected = (uint8_t *)(data + offset);
		offset += sizeof(bool);

		__block MCUCI::NodeConnectionInfo connectionInfo;
		__block bool connected;

		memcpy(&connectionInfo, ptrConnectionInfo, sizeof(connectionInfo));
		memcpy(&connected, ptrConnected, sizeof(connected));

		if (_nodeConnectionBlock != nil) {
			dispatch_async(_queue, ^{
			  assert(self->_partitionIdx >= 0);
			  auto extendedNodeId = toExtendedNodeId(connectionInfo.node, (uint32_t)self->_partitionIdx);
			  self->_nodeConnectionBlock(TX, connectionInfo.channelIndex, extendedNodeId, connected);
			});
		}
		break;
	}
	case MCUCI::Notification::RXNodeConnectionChange: {
		MCUCI::NodeConnectionInfo * ptrConnectionInfo = (MCUCI::NodeConnectionInfo *)(data + offset);
		offset += sizeof(MCUCI::NodeConnectionInfo);

		uint8_t * ptrConnected = (uint8_t *)(data + offset);
		offset += sizeof(bool);

		__block MCUCI::NodeConnectionInfo connectionInfo;
		__block bool connected;

		memcpy(&connectionInfo, ptrConnectionInfo, sizeof(connectionInfo));
		memcpy(&connected, ptrConnected, sizeof(connected));

		if (_nodeConnectionBlock != nil) {
			dispatch_async(_queue, ^{
			  assert(self->_partitionIdx >= 0);
			  auto extendedNodeId = toExtendedNodeId(connectionInfo.node, (uint32_t)self->_partitionIdx);
			  self->_nodeConnectionBlock(RX, connectionInfo.channelIndex, extendedNodeId, connected);
			});
		}
		break;
	}
	}
}

- (void)meshMessageReceived
{
	_totalCallbackCount++;

	if (_shuttingDown) {
		return;
	}

	mach_msg_size_t size    = sizeof(mach_msg_header_t) + MAX_TRAILER_SIZE;
	mach_msg_header_t * msg = (mach_msg_header_t *)CFAllocatorAllocate(kCFAllocatorDefault, size, 0);
	msg->msgh_size          = size;

	for (;;) {
		msg->msgh_bits        = 0;
		msg->msgh_local_port  = _dataQueuePort;
		msg->msgh_remote_port = MACH_PORT_NULL;
		msg->msgh_id          = 0;
		kern_return_t ret     = mach_msg(msg,
		                                 MACH_RCV_MSG | MACH_RCV_LARGE | MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0) |
		                                     MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AV),
		                                 0, msg->msgh_size, _dataQueuePort, 0, MACH_PORT_NULL);

		if (MACH_MSG_SUCCESS == ret)
			break;

		if (MACH_RCV_TOO_LARGE != ret) {
			LogError("FATAL ERROR: bad state");
			exit(1);
		}

		uint32_t newSize = round_msg(msg->msgh_size + MAX_TRAILER_SIZE);
		msg              = (mach_msg_header_t *)CFAllocatorReallocate(kCFAllocatorDefault, msg, newSize, 0);
		msg->msgh_size   = newSize;

		_totalNotificationCount++;
	}

	[self meshMessagExplicitRead];
}

- (void)meshMessagExplicitRead
{
	IODataQueueEntry * nextEntry;
	IODataQueueMemory * queueMemory = reinterpret_cast<IODataQueueMemory *>(_dataQueueAddr);

	while ((nextEntry = IODataQueuePeek(queueMemory))) {
		_totalDequeueCount++;

		// data field is a byte array with a ptr in it...
		MCUCI::MeshMessage * message = (MCUCI::MeshMessage *)nextEntry->data;

		if (!message) {
			LogError("FATAL ERROR: bad data ptr");
			exit(1);
		}

		__block MCUCI::MeshMessage copyMessage;

		assert(_partitionIdx >= 0);
		auto extendedNodeId = toExtendedNodeId(message->node, _partitionIdx);
		copyMessage.node    = extendedNodeId;
		copyMessage.length  = message->length;
		memcpy(copyMessage.rawData, message->rawData, message->length);

		uint32_t dataSize = 0;
		IOReturn tmp      = IODataQueueDequeue(queueMemory, nullptr, &dataSize);
		if (kIOReturnSuccess != tmp) {
			LogError("bad dequeue %x", tmp);
			exit(1);
		}

		if (_nodeMessageBlock != nil) {
			dispatch_async(_queue, ^{
			  NSData * data = [NSData dataWithBytes:copyMessage.rawData length:copyMessage.length];

			  assert(self->_partitionIdx >= 0);
			  auto extendedNodeId = toExtendedNodeId(copyMessage.node, (uint32_t)self->_partitionIdx);
			  self->_nodeMessageBlock(extendedNodeId, data);
			});
		}
	}
}

- (BOOL)onMeshChannelChange:(MeshChannelChangeBlock)block
{
	if (_queue == nullptr || ![self notifyRegister]) {
		return NO;
	}

	LogInfo("mesh channel change block registered");

	_meshChannelBlock = block;
	return YES;
}

- (BOOL)onNodeConnectionChange:(NodeConnectionChangeBlock)block
{
	if (_queue == nullptr || ![self notifyRegister]) {
		return NO;
	}

	LogInfo("node connection change block registered");

	_nodeConnectionBlock = block;
	return YES;
}

- (BOOL)onNodeNetworkConnectionChange:(NodeNetworkConnectionChangeBlock)block
{
	if (_queue == nullptr || ![self notifyRegister]) {
		return NO;
	}

	LogInfo("node network connection change block registered");

	_nodeNetworkConnectionBlock = block;
	return YES;
}

- (BOOL)onNodeMessage:(NodeMessageBlock)block
{
	if (_queue == nullptr || ![self notifyRegister]) {
		return NO;
	}

	LogInfo("node message block registered");

	_nodeMessageBlock = block;
	return YES;
}

#pragma mark - API

- (BOOL)setNodeId:(uint32_t)nodeId
{
	return [self setExtendedNodeId:nodeId];
}

- (BOOL)setExtendedNodeId:(uint32_t)nodeId
{
	MCUCI::NodeId node = (MCUCI::NodeId)nodeId;

	require([self open], fail);

	if (IOConnectCallStructMethod(_connection, MCUCI::Method::SetExtendedNodeId, &node, sizeof(node), nullptr, 0) !=
	    kIOReturnSuccess) {
		LogError("could not set nodeId");
		goto fail;
	}

	_partitionIdx = nodeId / 8;
	// This should not be used to retrieve the nodeId.
	// getExtendedNodeId should be used instead.
	// This is only used when doing the handshake with peernodes (if any).
	_nodeId = (int)nodeId;

	return YES;

fail:
	return NO;
}

- (BOOL)getNodeId:(uint32_t *)nodeId
{
	return [self getExtendedNodeId:nodeId];
}

- (BOOL)getExtendedNodeId:(uint32_t *)nodeId
{
	size_t nodeSz = sizeof(uint32_t);

	require([self open], fail);

	if (IOConnectCallStructMethod(_connection, MCUCI::Method::GetExtendedNodeId, nullptr, 0, (MCUCI::NodeId *)nodeId, &nodeSz) !=
	    kIOReturnSuccess) {
		LogError("could not get extended nodeId");
		goto fail;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)getLocalNodeId:(uint32_t *)nodeId
{
	size_t nodeSz = sizeof(uint32_t);

	require([self open], fail);

	if (IOConnectCallStructMethod(_connection, MCUCI::Method::GetLocalNodeId, nullptr, 0, (MCUCI::NodeId *)nodeId, &nodeSz) !=
	    kIOReturnSuccess) {
		LogError("could not get local nodeId");
		goto fail;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)getEnsembleSize:(uint32_t *)ensembleSize
{
	size_t ensembleSizeSz = sizeof(uint32_t);

	require([self open], fail);

	if (IOConnectCallStructMethod(_connection, MCUCI::Method::GetEnsembleSize, nullptr, 0, (MCUCI::EnsembleSize *)ensembleSize,
	                              &ensembleSizeSz) != kIOReturnSuccess) {
		LogError("could not get ensemble size");
		goto fail;
	}
	return YES;

fail:
	return NO;
}

- (BOOL)setEnsembleSize:(uint32_t)ensembleSize
{
	MCUCI::EnsembleSize ensemble = (MCUCI::EnsembleSize)ensembleSize;

	require([self open], fail);

	if (IOConnectCallStructMethod(_connection, MCUCI::Method::SetEnsembleSize, &ensemble, sizeof(ensemble), nullptr, 0) !=
	    kIOReturnSuccess) {
		LogError("could not set ensemble size");
		goto fail;
	}

	return YES;

fail:
	return NO;
}

- (NSMutableArray *)getPeerNodeRanks:(uint32_t)nodeId nodeCount:(uint32_t)nodeCount
{
	NSMutableArray * peerNodes = [NSMutableArray array];

	uint32_t mod = nodeId % 8;

	for (uint32_t i = 0; i < nodeCount; i++) {
		if (i != nodeId && i % 8 == mod) {
			[peerNodes addObject:@(i)];
		}
	}

	return peerNodes;
}

- (BOOL)setChassisId:(NSString *)chassisId
{
	MCUCI::ChassisId chassis;
	strncpy(chassis.id, [chassisId UTF8String], kMaxChassisIdLength);

	require([self open], fail);

	if (IOConnectCallStructMethod(_connection, MCUCI::Method::SetChassisId, &chassis, sizeof(chassis), nullptr, 0) !=
	    kIOReturnSuccess) {
		LogError("could not set chassisId");
		goto fail;
	}

	return YES;

fail:
	return NO;
}

- (NSArray *)getPeerHostnames
{
	check([self open]);

	MCUCI::PeerHostnames peerHostnames;
	size_t hostnamesSize = sizeof(peerHostnames);

	if (IOConnectCallStructMethod(_connection, MCUCI::Method::GetPeerHostnames, nullptr, 0, &peerHostnames, &hostnamesSize) !=
	    kIOReturnSuccess) {
		LogError("could not get peer hostnames");
		return NULL;
	}

	// Create an array of NSStrings from the peer hostnames and return it.
	NSMutableArray * hostnames = [[NSMutableArray alloc] init];
	for (int i = 0; i < peerHostnames.count; i++) {
		PeerNodeInfo info;
		info.nodeId = peerHostnames.peers[i].nodeId;
		strncpy(info.hostname, peerHostnames.peers[i].hostname, kMaxHostnameLength);
		[hostnames addObject:[NSValue valueWithBytes:&info objCType:@encode(PeerNodeInfo)]];
	}
	return hostnames;
}

- (BOOL)addPeerHostname:(NSString *)peerNodeHostname peerNodeId:(uint32_t)peerNodeId
{
	// Check each hostname in the array and ensure it's length is less than the maximum.
	if (peerNodeHostname.length > kMaxHostnameLength) {
		LogError("Hostname is too long. Hostname: %@", peerNodeHostname);
		return NO;
	}

	MCUCI::PeerNode peerNode;
	peerNode.nodeId = peerNodeId;
	strncpy(peerNode.hostname, [peerNodeHostname UTF8String], kMaxHostnameLength);

	require([self open], fail);

	if (IOConnectCallStructMethod(_connection, MCUCI::Method::AddPeerHostname, &peerNode, sizeof(peerNode), nullptr, 0) !=
	    kIOReturnSuccess) {
		LogError("could not set hostname");
		goto fail;
	}

	_peerHostname = [peerNodeHostname UTF8String];
	_peerNodeId   = peerNodeId;
	// if we added at least one peer, then mark this as extended and therefore requires network activation.
	_isExtendedMesh = true;

	return YES;
fail:
	return NO;
}

- (BOOL)activateCIO
{
	require([self open], fail);

	if (IOConnectCallStructMethod(_connection, MCUCI::Method::Activate, nullptr, 0, nullptr, 0) != kIOReturnSuccess) {
		LogError("could not activate CIO");
		goto fail;
	}

	if (_isExtendedMesh) {
		dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
		dispatch_async(q, ^{ [self activateNetworkPeers]; });
	}

	return YES;

fail:
	return NO;
}

- (BOOL)deactivateCIO
{
	require([self open], fail);

	if (IOConnectCallStructMethod(_connection, MCUCI::Method::Deactivate, nullptr, 0, nullptr, 0) != kIOReturnSuccess) {
		LogError("could not deactivate CIO");
		goto fail;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)lockCIO
{
	require([self open], fail);

	if (IOConnectCallStructMethod(_connection, MCUCI::Method::Lock, nullptr, 0, nullptr, 0) != kIOReturnSuccess) {
		LogError("could not lock CIO");
		goto fail;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)isCIOLocked
{
	require([self open], fail);

	if (IOConnectCallStructMethod(_connection, MCUCI::Method::IsLocked, nullptr, 0, nullptr, 0) != kIOReturnSuccess) {
		return NO;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)disconnectCIOChannel:(uint32_t)channelIndex
{
	MCUCI::MeshChannelIdx channel = (MCUCI::MeshChannelIdx)channelIndex;

	require([self open], fail);

	if (IOConnectCallStructMethod(_connection, MCUCI::Method::DisconnectCIOChannel, &channel, sizeof(channel), nullptr, 0) !=
	    kIOReturnSuccess) {
		LogError("could not disconnect CIO channel %d", channelIndex);
		goto fail;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)establishTXConnection:(uint32_t)sourceNode onChannel:(uint32_t)channelIndex
{
	MCUCI::NodeConnectionInfo connection;
	const auto localNodeId  = sourceNode % 8;
	connection.node         = localNodeId;
	connection.channelIndex = channelIndex;

	require([self open], fail);

	if (IOConnectCallStructMethod(_connection, MCUCI::Method::EstablishTxConnection, &connection, sizeof(connection), nullptr, 0) !=
	    kIOReturnSuccess) {
		LogError("could not establish TX connection from node:%d on cioChannel:%d", sourceNode, channelIndex);
		goto fail;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)sendControlMessage:(NSData *)message toNode:(uint32_t)node
{
	if (message.length > kMaxMessageLength) {
		LogError("Control messages are limited to %d bytes. message is %lu bytes", kMaxMessageLength,
		         static_cast<unsigned long>(message.length));
		return NO;
	}

	MCUCI::MeshMessage meshMessage;

	auto localNodeId   = node % 8;
	meshMessage.node   = localNodeId;
	meshMessage.length = message.length;
	memcpy(meshMessage.rawData, message.bytes, message.length);

	require([self open], fail);

	if (IOConnectCallStructMethod(_connection, MCUCI::Method::SendControlMessage, &meshMessage, sizeof(meshMessage), nullptr, 0) !=
	    kIOReturnSuccess) {
		LogError("could not send control message to node:%d", node);
		goto fail;
	}

	return YES;

fail:
	return NO;
}

- (BOOL)getHardwareState:(uint32_t *)linksPerChannel
{
	MCUCI::HardwareState hardwareState;
	size_t argSz = sizeof(MCUCI::HardwareState);

	require([self open], fail);

	if (IOConnectCallStructMethod(_connection, MCUCI::Method::GetHardwareState, nullptr, 0, (MCUCI::HardwareState *)&hardwareState,
	                              &argSz) != kIOReturnSuccess) {
		LogError("could not get hardware state");
		goto fail;
	}

	*linksPerChannel = hardwareState.meshLinksPerChannel;

	return YES;

fail:
	return NO;
}

- (NSArray *)getConnectedNodes
{
	MCUCI::ConnectedNodes connectedNodes;
	size_t argSz      = sizeof(MCUCI::ConnectedNodes);
	kern_return_t res = kIOReturnError;

	NSMutableArray * nodes = [[NSMutableArray alloc] init];

	require([self open], fail);

	res = IOConnectCallStructMethod(_connection, MCUCI::Method::GetConnectedNodes, nullptr, 0,
	                                (MCUCI::ConnectedNodes *)&connectedNodes, &argSz);
	if (kIOReturnSuccess != res) {
		LogError("Could not get connected nodes [0x%x]: %s", res, mach_error_string(res));
		goto fail;
	}

	for (uint32_t i = 0; i < connectedNodes.nodeCount; i++) {
		NSMutableDictionary * nodeDict = [[NSMutableDictionary alloc] init];
		if (connectedNodes.nodes[i].rank == 255) {
			continue;
		}

		[nodeDict setValue:@(connectedNodes.nodes[i].rank) forKey:@"rank"];
		[nodeDict setValue:@(connectedNodes.nodes[i].inputChannel) forKey:@"inputChannel"];
		size_t chassisLen  = strnlen(connectedNodes.nodes[i].chassisId.id, kMaxChassisIdLength);
		NSString * chassis = [[NSString alloc] initWithBytes:connectedNodes.nodes[i].chassisId.id
		                                              length:chassisLen
		                                            encoding:NSUTF8StringEncoding];
		[nodeDict setValue:chassis forKey:@"chassis"];

		if (connectedNodes.nodes[i].outputChannelCount > 0) {
			NSMutableArray * outputChannels = [[NSMutableArray alloc] init];
			for (int j = 0; j < connectedNodes.nodes[i].outputChannelCount; j++) {
				[outputChannels addObject:@(connectedNodes.nodes[i].outputChannels[j])];
			}
			[nodeDict setValue:outputChannels forKey:@"outputChannels"];
		}

		[nodes addObject:nodeDict];
	}

	return nodes;

fail:
	return nil;
}

- (BOOL)getConnectedNodesRaw:(MeshConnectedNodeInfo *)connectedNodes
{
	size_t argSz = sizeof(MCUCI::ConnectedNodes);

	if (sizeof(MeshConnectedNodeInfo) < argSz) {
		LogError("Mismatched ConnectedNode info sizes: %zd < %zd", sizeof(MeshConnectedNodeInfo), argSz);
		return NO;
	}

	require([self open], fail);

	if (IOConnectCallStructMethod(_connection, MCUCI::Method::GetConnectedNodes, nullptr, 0,
	                              (MCUCI::ConnectedNodes *)connectedNodes, &argSz) != kIOReturnSuccess) {
		LogError("could not get connected nodes");
		goto fail;
	}

	return YES;

fail:
	return NO;
}

- (NSArray *)getCIOCableState
{
	MCUCI::CIOConnections cioConnections;
	size_t argSz = sizeof(MCUCI::CIOConnections);

	NSMutableArray * nodes = [[NSMutableArray alloc] init];

	require([self open], fail);

	if (IOConnectCallStructMethod(_connection, MCUCI::Method::GetCIOConnectionState, nullptr, 0,
	                              (MCUCI::ConnectedNodes *)&cioConnections, &argSz) != kIOReturnSuccess) {
		LogError("could not get cio connection state");
		goto fail;
	}

	for (uint32_t i = 0; i < cioConnections.cioCount; i++) {
		NSMutableDictionary * nodeDict = [[NSMutableDictionary alloc] init];

		[nodeDict setValue:@(cioConnections.cio[i].cableConected) forKey:@"cableConnected"];
		[nodeDict setValue:@(cioConnections.cio[i].expectedPeerHardwareNodeId) forKey:@"expectedPartnerHardwareNode"];
		[nodeDict setValue:@(cioConnections.cio[i].actualPeerHardwareNodeId) forKey:@"actualPartnerHardwareNode"];

		[nodes addObject:nodeDict];
	}

	return nodes;

fail:
	return nil;
}

- (BOOL)setCryptoKey:(NSData *)keyData andFlags:(uint32_t)flags
{
	MCUCI::CryptoInfo cryptoInfo;

	require([self open], fail);

	cryptoInfo.keyData    = (void *)[keyData bytes];
	cryptoInfo.keyDataLen = [keyData length];
	cryptoInfo.flags      = (MCUCI::CryptoFlags)flags;

	if (IOConnectCallStructMethod(_connection, MCUCI::Method::SetCryptoKey, &cryptoInfo, sizeof(cryptoInfo), nullptr, 0) !=
	    kIOReturnSuccess) {
		LogError("could not set the crypto key (keyData %p len %zd and flags 0x%x)\n", keyData, [keyData length], flags);
		goto fail;
	}

	return YES;

fail:
	return NO;
}

- (NSData *)getCryptoKeyForSize:(size_t)keySize andFlags:(uint32_t *)flags
{
	size_t argSz;
	MCUCI::CryptoInfo cryptoInfo;
	MCUCI::CryptoInfo cryptoInfoOutput;
	char rawKeyData[32];
	NSData * keyData = nil;

	require([self open], fail);

	argSz                 = sizeof(cryptoInfo);
	cryptoInfo.keyData    = (void *)&rawKeyData[0];
	cryptoInfo.keyDataLen = keySize;

	if (IOConnectCallStructMethod(_connection, MCUCI::Method::GetCryptoKey, &cryptoInfo, argSz, &cryptoInfoOutput, &argSz) !=
	    kIOReturnSuccess) {
		LogError("could not get the crypto key\n");
		goto fail;
	}

	keyData = [[NSData alloc] initWithBytes:&rawKeyData[0] length:cryptoInfoOutput.keyDataLen];
	*flags  = (uint32_t)cryptoInfoOutput.flags;

fail:
	return keyData;
}

- (uint64_t)getMaxBuffersPerCryptoKey
{
	return kMaxBuffersPerCryptoKey;
}

- (uint64_t)getMaxSecondsPerCryptoKey
{
	return kMaxSecondsPerCryptoKey;
}

- (uint64_t)getBuffersUsedForCryptoKey
{
	uint64_t buffersUsed = 0;
	size_t outSz         = sizeof(buffersUsed);

	require([self open], fail);

	if (IOConnectCallStructMethod(_connection, MCUCI::Method::GetBuffersUsedByKey, NULL, 0, &buffersUsed, &outSz) !=
	    kIOReturnSuccess) {
		LogError("could not get the buffers used\n");
		goto fail;
	}

	return buffersUsed;

fail:
	return 0;
}

- (BOOL)canActivate:(uint32_t)meshNodeCount
{
	MCUCI::MeshNodeCount count = (MCUCI::MeshNodeCount)meshNodeCount;

	require([self open], fail);

	if (IOConnectCallStructMethod(_connection, MCUCI::Method::canActivate, &count, sizeof(count), nullptr, 0) != kIOReturnSuccess) {
		return NO;
	}

	return YES;

fail:
	return NO;
}

static MeshUtils::Optional<MeshNet::TcpConnection>
waitForConnection(AppleCIOMeshConfigServiceRef * service)
{
	using AppleCIOMeshUtils::Optional;
	auto tcpListener = MeshNet::TcpConnectionListener::listen(service->_logger, kPort);
	if (tcpListener.has_value() == false) {
		return AppleCIOMeshUtils::nullopt;
	}
	while (service->_shuttingDown == false) {
		fd_set readfds;
		FD_ZERO(&readfds);
		FD_SET(tcpListener->socket(), &readfds);
		// Set the timeout to 1 second.
		struct timeval timeout;
		timeout.tv_sec  = 1;
		timeout.tv_usec = 0;
		const int maxfd = tcpListener->socket();
		int ret         = ::select(maxfd + 1, &readfds, NULL, NULL, &timeout);
		if (ret < 0) {
			os_log_error(service->_logger, "Failed to select on the socket.");
			continue;
		}

		if (ret == 0) { // timeout
			continue;
		}

		Optional<MeshNet::TcpConnection> conn = tcpListener.value().accept();
		if (!conn.has_value()) {
			os_log_error(service->_logger, "Failed to accept network connection.");
			continue;
		}
		// In the future, we will need to handle multiple connections.
		// TODO (marco): Add support for 32n mesh.
		os_log_info(service->_logger, "Accepted network connection\n");
		return conn;
	}
	return AppleCIOMeshUtils::nullopt;
}

- (void)activateNetworkPeers
{
	// TODO (marco): Add support for 32n mesh.
	MeshNet::Handshake receivedHandshake;

	AppleCIOMeshNet::Handshake sentHandshake;
	sentHandshake.version        = kHandshakeVersion;
	sentHandshake.message_type   = kHandshakeMessageType;
	sentHandshake.sender_rank    = (uint32_t)_nodeId;
	sentHandshake.message_length = sizeof(kHandshakeMessage);
	memcpy(sentHandshake.message, kHandshakeMessage, sizeof(kHandshakeMessage));

	if (_partitionIdx == 0) {
		auto peerConnection = waitForConnection(self);
		if (peerConnection.has_value() == false) {
			dispatch_async(_queue, ^{ self->_nodeNetworkConnectionBlock(self->_peerNodeId, false); });
		}
		LogDebug("Waiting for handshake from peer %s\n", _peerHostname.c_str());
		bool success = verifyHandshake(_logger, peerConnection.value(), &receivedHandshake, _peerNodeId);
		if (!success) {
			LogError("Failed to verify handshake.");
			if (self->_nodeNetworkConnectionBlock != nil) {
				dispatch_async(_queue, ^{ self->_nodeNetworkConnectionBlock(self->_peerNodeId, false); });
			}
			return;
		}
		sendHandshake(sentHandshake, _logger, peerConnection.value());
	} else {
		while (_shuttingDown == false) {
			// We will actively try to connect to the other peer.
			LogInfo("Attempting to connect to peer %s\n", _peerHostname.c_str());
			auto conn = MeshNet::TcpConnection::connect(_logger, _peerHostname.c_str(), kPort);
			if (!conn.has_value()) {
				LogError("Failed to connect to the peer node %s. Will try again in 1 second.", _peerHostname.c_str());
				usleep(1000 * 1000);
				continue;
			}
			LogDebug("Successfully connected to peer %s. Sending a handshake message.\n", _peerHostname.c_str());
			// Send a handshake to the peer.
			sendHandshake(sentHandshake, _logger, conn.value());
			LogDebug("Handshake sent. Waiting for response.\n");
			if (verifyHandshake(_logger, conn.value(), &receivedHandshake, _peerNodeId)) {
				LogDebug("Handshake verified.\n");
				break;
			} else {
				LogError("Failed to verify handshake\n");
				if (self->_nodeNetworkConnectionBlock != nil) {
					dispatch_async(_queue, ^{ self->_nodeNetworkConnectionBlock(self->_peerNodeId, false); });
				}
				return;
			}
		}
	}

	Log("Successfully activated network peers\n");
	if (self->_nodeNetworkConnectionBlock != nil) {
		dispatch_async(_queue, ^{ self->_nodeNetworkConnectionBlock(self->_peerNodeId, true); });
	}
}

@end
