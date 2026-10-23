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
//  UserClientMain.h
//  AppleVirtMesh
//
//  Created by Zixuan Wang on 11/19/24.
//

#pragma once

#include "VirtMesh/Guest/AppleVirtMesh/Interfaces.h"
#include "VirtMesh/Guest/AppleVirtMesh/UserClient.h"

namespace VirtMesh::Guest::Mesh
{

static constexpr uint64_t kNsPerSecond = 1e9;

class AppleVirtMeshMainUserClient : public AppleVirtMeshBaseUserClient
{
	OSDeclareDefaultStructors(AppleVirtMeshMainUserClient);
	using super = AppleVirtMeshBaseUserClient;

  public:
	bool start(IOService *) override;
	void stop(IOService * provider) override;

	IOReturn         externalMethod(uint32_t selector, IOExternalMethodArgumentsOpaque *) override;
	IOExternalTrap * getTargetAndTrapForIndex(IOService ** target_ptr, uint32_t trap_index) override;

	void notify_mesh_synchronized();

  private:
	static const IOExternalMethodDispatch2022 sExternalMethodDispatchTable[static_cast<int>(MainClient::Methods::TotalMethods)];

	/* clang-format off */
    static IOReturn notification_register       (OSObject *, void *, IOExternalMethodArguments *);
    static IOReturn notification_unregister     (OSObject *, void *, IOExternalMethodArguments *);
    static IOReturn allocate_shared_memory      (OSObject *, void *, IOExternalMethodArguments *);
    static IOReturn deallocate_shared_memory    (OSObject *, void *, IOExternalMethodArguments *);
    static IOReturn assign_shared_memory_chunk  (OSObject *, void *, IOExternalMethodArguments *);
    static IOReturn print_buffer_state          (OSObject *, void *, IOExternalMethodArguments *) { return kIOReturnUnsupported; } /* Not used */
    static IOReturn setup_forward_chain_buffers (OSObject *, void *, IOExternalMethodArguments *) { return kIOReturnUnsupported; } /* I don't think it should be used in two-node VRE. */
    static IOReturn set_max_wait_time           (OSObject *, void *, IOExternalMethodArguments *);
    static IOReturn set_max_wait_per_node_batch (OSObject *, void *, IOExternalMethodArguments *); /* Not used but still implemented just in case */
    static IOReturn synchronize_generation      (OSObject *, void *, IOExternalMethodArguments *);
    static IOReturn override_runtime_prepare    (OSObject *, void *, IOExternalMethodArguments *);
	/* clang-format on */

	static const IOExternalTrap sExternalTrapDispatchTable[static_cast<int>(MainClient::Traps::TotalTraps)];

	/* clang-format off */
	using ut = uintptr_t;
	IOReturn wait_shared_memory_chunk      (ut buffer_id                 , ut offset                              , ut tag_out                                                                                                                                           );
	IOReturn send_assigned_data            (ut buffer_id                 , ut offset                              , ut tag_all                                                                                                                                           );
	IOReturn prepare_chunk                 (ut buffer_id                 , ut offset                                                                                                                                                                                     );
	IOReturn prepare_all_chunks            (ut buffer_id                 , ut direction                                                                                                                                                                                  );
	IOReturn send_and_prepare_chunk        (ut buffer_id_send            , ut offset_send                         , ut buffer_id_prep             , ut offset_prep                        , ut tag_all                                                                   );
	IOReturn send_all_assigned_chunks      (ut buffer_id                 , ut tag_all                                                                                                                                                                                    );
	IOReturn receive_all                   (ut buffer_id [[maybe_unused]]                                                                                                                                                                                                ) { return kIOReturnUnsupported; } /* Not used */
	IOReturn receive_next                  (ut buffer_id [[maybe_unused]], ut offset_out_received [[maybe_unused]], ut tag_out    [[maybe_unused]]                                                                                                                       ) { return kIOReturnUnsupported; } /* Not used */
	IOReturn receive_batch                 (ut buffer_id [[maybe_unused]], ut batch_count         [[maybe_unused]], ut timeout_us [[maybe_unused]], ut count_received_out [[maybe_unused]], ut offset_received_out [[maybe_unused]], ut tag_received_out [[maybe_unused]]) { return kIOReturnUnsupported; } /* Not used, the 'from_node' version is used instead */
	IOReturn receive_batch_for_node        (ut buffer_id                 , ut node_id                             , ut count_batch                , ut count_received_out                 , ut offset_received_out                 , ut tag_received_out                 );
	IOReturn interrupt_waiting_threads     (ut buffer_id                                                                                                                                                                                                                 );
	IOReturn clear_interrupt_state         (ut buffer_id                                                                                                                                                                                                                 );
	IOReturn interrupt_receive_batch       (                                                                                                                                                                                                                             ) { return kIOReturnUnsupported; } /* Not used */
	IOReturn start_forward_chain           (ut chain_id                  , ut elements                                                                                                                                                                                   );
	IOReturn stop_forward_chain            (                                                                                                                                                                                                                             );
	/* clang-format on */

	/**
	 * @todo this is a dup variable from driver class. CIOMesh has this dup variable, maybe remove it from this user client class?
	 * @note: per_node default value 5000 comes from CIOMesh kext kDefaultMaxWaitBatchNodeNS
	 */
	uint64_t _max_wait_time          = UINT64_MAX; /* in mach_absolute_time() units */
	uint64_t _max_wait_time_per_node = 5000;       /* in mach_absolute_time() units */

  protected:
	void
	construct_logger() override
	{
		if (_logger == nullptr) {
			_logger = os_log_create(kDriverLoggerSubsystem, "AppleVirtMeshMainUserClient");
		}
	}
};
}; // namespace VirtMesh::Guest::Mesh
