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
//  BrokerMain.mm
//  AppleVirtMeshBroker
//
//  Created by Zixuan Wang on 11/12/24.
//

#include <AppServerSupport/AppServerSupport.h>
#include <CoreFoundation/CFXPCBridge.h>
#include <Foundation/Foundation.h>
#include <launch_priv.h>
#include <mach-o/dyld.h>
#include <os/log.h>
#include <xpc/private.h>

@interface Plugin : NSObject

@property(nullable, nonatomic) xpc_session_t  session;
@property(nullable, nonatomic) xpc_endpoint_t endpoint;
@property(nullable, nonatomic) NSUUID *       instance;

@end

@implementation Plugin

@end

static os_log_t _logger = os_log_create("com.apple.AppleVirtMesh", "Broker");

static void
broker_notify_plugin(Plugin * browsing, Plugin * discovered)
{
	xpc_object_t message = xpc_dictionary_create_empty();
	xpc_dictionary_set_value(message, "peer", discovered.endpoint);

	xpc_rich_error_t error = xpc_session_send_message(browsing.session, message);
	if (error != nil) {
		os_log(_logger, "AppleVirtMeshBroker: failed to notify %@ about %@", browsing.instance, discovered.instance);
	}
}

static void
broker_handle_new_plugin(Plugin * new_plugin, NSMutableDictionary<NSUUID *, Plugin *> * plugins)
{
	for (NSUUID * instance in plugins) {
		Plugin * plugin = plugins[instance];

		broker_notify_plugin(plugin, new_plugin);
		broker_notify_plugin(new_plugin, plugin);
	}

	plugins[new_plugin.instance] = new_plugin;
}

static void
broker_handle_session(xpc_session_t session, NSMutableDictionary<NSUUID *, Plugin *> * plugins)
{
	__block NSUUID * instance = nil;
	xpc_session_set_incoming_message_handler(session, ^(xpc_object_t message) {
	  const uint8_t * instance_bytes = xpc_dictionary_get_uuid(message, "instance");
	  instance                       = [[NSUUID alloc] initWithUUIDBytes:instance_bytes];
	  os_log(_logger, "AppleVirtMeshBroker: session %@ connected", instance);

	  Plugin * plugin = [Plugin new];
	  plugin.session  = session;
	  plugin.endpoint = xpc_dictionary_get_value(message, "endpoint");
	  plugin.instance = instance;

	  broker_handle_new_plugin(plugin, plugins);
	});

	xpc_session_set_cancel_handler(session, ^(xpc_rich_error_t __unused error) {
	  os_log(_logger, "AppleVirtMeshBroker: session %@ disconnected", instance);
	  plugins[instance] = nil;

	  if (plugins.count == 0) {
		  os_log(_logger, "AppleVirtMeshBroker: no more plugins, exiting");
		  exit(0);
	  }
	});
}

static void
broker_main(void)
{
	os_log(_logger, "AppleVirtMeshBroker: broker_main()");

	NSMutableDictionary<NSUUID *, Plugin *> * plugins = [NSMutableDictionary new];
	xpc_listener_incoming_session_handler_t   handler = ^(xpc_session_t session) { broker_handle_session(session, plugins); };
	xpc_rich_error_t                          error   = nil;
	xpc_listener_t                            listener =
	    xpc_listener_create("com.apple.AppleVirtMeshBroker", dispatch_get_main_queue(), XPC_LISTENER_CREATE_NONE, handler, &error);

	if (listener == nil) {
		os_log_error(_logger, "AppleVirtMeshBroker: Failed to create listener: %s", xpc_rich_error_copy_description(error));
		exit(1);
	}

	dispatch_main();
}

int
main(int __unused argc, const char __unused * argv[])
{
	broker_main();
	return 0;
}
