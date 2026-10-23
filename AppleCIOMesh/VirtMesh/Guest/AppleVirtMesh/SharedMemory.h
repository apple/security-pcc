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
//  SharedMemory.h
//  AppleVirtMesh
//
//  Created by Zixuan Wang on 1/27/25.
//

#pragma once

#include "VirtMesh/Guest/AppleVirtMesh/Config.h"
#include "VirtMesh/Guest/AppleVirtMesh/Interfaces.h"
#include "VirtMesh/Guest/AppleVirtMesh/UserClientMain.h"
#include <libkern/c++/OSObject.h>
#include <os/atomic.h>

namespace VirtMesh::Guest::Mesh
{

static constexpr uint32_t kMaxAssignmentCount = 512;

class AppleVirtMeshDriver;
class AppleVirtMeshSharedMemory;

class AppleVirtMeshAssignment final : public OSObject
{
	OSDeclareDefaultStructors(AppleVirtMeshAssignment);
	using super = OSObject;

  public:
	static OSSharedPtr<AppleVirtMeshAssignment>
	allocate(AppleVirtMeshSharedMemory * shared_memory, MainClient::MeshDirection direction)
	{
		auto assignment = OSMakeShared<AppleVirtMeshAssignment>();

		if (nullptr == assignment || !assignment->initialize(shared_memory, direction)) {
			OSSafeReleaseNULL(assignment);
		}

		return assignment;
	}

	bool
	initialize(AppleVirtMeshSharedMemory * shared_memory, MainClient::MeshDirection direction)
	{
		_shared_memory = shared_memory;
		_direction     = direction;
		return true;
	}

	void
	set_rx_node(ConfigClient::NodeId node)
	{
		assertf(MainClient::MeshDirection::In == _direction, "Can only set rx node for MeshDirection::In assignment");
		_rx_node = node;
	}

	MainClient::MeshDirection
	get_direction()
	{
		return _direction;
	}

  private:
	ConfigClient::NodeId        _rx_node;
	MainClient::MeshDirection   _direction;
	AppleVirtMeshSharedMemory * _shared_memory;
};

struct AssignmentMap {
	uint64_t             offset[kMaxAssignmentCount];
	ConfigClient::NodeId node[kMaxAssignmentCount];
	char                 tag[kMaxAssignmentCount][Config::kTagSize];
	bool                 ready[kMaxAssignmentCount];
	bool                 notified[kMaxAssignmentCount];
	uint32_t             count;
	atomic_uint          remaining;
	atomic_bool          all_receive_finished;

	MainClient::MeshDirection   direction;
	AppleVirtMeshSharedMemory * shared_memory;

	/* TODO: Missing a few fields from AppleCIOMeshAssignmentMap, double check and see if they affect behaviors. */
};

class AppleVirtMeshSharedMemory final : public OSObject
{
	OSDeclareDefaultStructors(AppleVirtMeshSharedMemory);
	using super = OSObject;

  public:
	/* TODO: Use OSSharedPtr instead of raw pointer */
	static OSSharedPtr<AppleVirtMeshSharedMemory> allocate(
	    AppleVirtMeshDriver *                  driver,
	    const MainClient::SharedMemoryConfig * config,
	    AppleVirtMeshMainUserClient *          client,
	    task_t                                 owning_task
	);

	bool initialize(
	    AppleVirtMeshDriver *                  driver,
	    const MainClient::SharedMemoryConfig * config,
	    AppleVirtMeshMainUserClient *          client,
	    task_t                                 owning_task
	);

	void free() final;

	IOReturn create_assignment(uint64_t offset, MainClient::MeshDirection direction, ConfigClient::NodeId node_id);
	IOReturn get_assignment(uint64_t offset, AppleVirtMeshAssignment *& assignment);
	IOReturn get_assignment_at_index(uint64_t index, AppleVirtMeshAssignment *& assignment);

	unsigned
	get_assignment_count()
	{
		return _assignments->getCount();
	}

	uint64_t
	get_assignment_size()
	{
		return _assignment_size;
	}

	OSSharedPtr<IOMemoryDescriptor>
	get_memory_desc()
	{
		return _shared_memory_desc;
	}

	AppleVirtMeshMainUserClient *
	get_main_client()
	{
		return _client;
	}

  private:
	AppleVirtMeshDriver *           _driver;
	AppleVirtMeshMainUserClient *   _client;
	OSSharedPtr<OSArray>            _assignments;
	AssignmentMap                   _incoming_assignments;
	AssignmentMap                   _outgoing_assignments;
	OSSharedPtr<IOMemoryDescriptor> _shared_memory_desc = nullptr; /* User/Kernel shared memory descriptor */

	/* Size of each assignment chunk, i.e., covering _config.address[offset:offset_assignment_size]
	 * Default to 1 to prevent divide-by-zero if used without initialization
	 */
	uint64_t _assignment_size = 1;

	unsigned int get_index(uint64_t offset);

  public:
	MainClient::SharedMemoryConfig _config;

  private:
	os_log_t _logger = nullptr;

	void
	construct_logger()
	{
		if (nullptr == _logger) {
			_logger = os_log_create(kDriverLoggerSubsystem, "AppleVirtMeshSharedMemory");
		}
	}
};

}; // namespace VirtMesh::Guest::Mesh
