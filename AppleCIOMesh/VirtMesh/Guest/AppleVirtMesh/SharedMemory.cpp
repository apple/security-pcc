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
//  SharedMemory.cpp
//  AppleVirtMesh
//
//  Created by Zixuan Wang on 1/27/25.
//

#include "VirtMesh/Guest/AppleVirtMesh/SharedMemory.h"
#include "VirtMesh/Guest/AppleVirtMesh/Common.h"
#include "VirtMesh/Utils/Log.h"
#include <IOKit/IOBufferMemoryDescriptor.h>

using namespace VirtMesh::Guest::Mesh;

OSDefineMetaClassAndStructors(AppleVirtMeshSharedMemory, OSObject);
OSDefineMetaClassAndStructors(AppleVirtMeshAssignment, OSObject);

OSSharedPtr<AppleVirtMeshSharedMemory>
AppleVirtMeshSharedMemory::allocate(
    AppleVirtMeshDriver *                  driver,
    const MainClient::SharedMemoryConfig * config,
    AppleVirtMeshMainUserClient *          client,
    task_t                                 owning_task
)
{
	auto shared_memory = OSMakeShared<AppleVirtMeshSharedMemory>();

	if (nullptr != shared_memory && !shared_memory->initialize(driver, config, client, owning_task)) {
		/* OSSharedPtr does not need OSSafeReleaseNULL */
		shared_memory = nullptr;
	}

	return shared_memory;
}

bool
AppleVirtMeshSharedMemory::initialize(
    AppleVirtMeshDriver *                  driver,
    const MainClient::SharedMemoryConfig * config,
    AppleVirtMeshMainUserClient *          client,
    task_t                                 owning_task
)
{
	construct_logger();

	/* Note:
	 * 1. CIOMesh kext checks for memory alignments, I don't think they are needed here
	 * 2. CIOMesh kext has many code for CIO-specific setups, I don't think they are needed in VRE
	 */

	_driver = driver;
	_config = *config;
	_client = client;

	/* CIOMesh kext allocates 10 array elements, idk the reason behind. */
	_assignments = OSArray::withCapacity(10);
	if (nullptr == _assignments) {
		os_log_error(_logger, "Failed to allocate assignments");
		return false;
	}

	if (_config.strideSkip == 0) {
		for (uint64_t offset = 0; offset < _config.size; offset += _config.chunkSize) {
			_assignments->setObject(kOSBooleanFalse);
		}
	} else {
		for (uint64_t offset = 0; offset < _config.strideSkip; offset += _config.strideWidth) {
			_assignments->setObject(kOSBooleanFalse);
		}
	}

	/**
	 * @brief Set up user/kernel shared memory address
	 * @ref AppleCIOMeshThunderboltCommandGroups::initialize()
	 */
	if (nullptr == owning_task) {
		os_log_error(_logger, "Owning task is null");
		return false;
	}

	IOOptionBits options = kIODirectionOutIn | kIOMemoryKernelUserShared | kIOMemoryPhysicallyContiguous | kIOMapAnywhere;
	_shared_memory_desc = IOMemoryDescriptor::withAddressRange(_config.address, (mach_vm_size_t)_config.size, options, owning_task);
	if (nullptr == _shared_memory_desc) {
		os_log_error(_logger, "Failed to allocate memory descriptor");
		return false;
	}

	_shared_memory_desc->prepare(kIODirectionInOut);

	/** @ref AppleCIOMeshSharedMemory::_getOffsetIdx() */
	_assignment_size = _config.strideSkip == 0 ? _config.chunkSize : _config.strideWidth;

	if (_assignment_size > MainClient::kMaxBufferChunkSize) {
		os_log_error(
		    _logger,
		    "VirtIO queue limits the single transaction size, practically [%llu] bytes can be used for a single transaction, while "
		    "trying to set it as [%llu] for buffer id [%llu]",
		    MainClient::kMaxBufferChunkSize,
		    _assignment_size,
		    _config.bufferId
		);

		return false;
	}

	return true;
}

void
AppleVirtMeshSharedMemory::free()
{
	/* TODO: free _assignments */
	super::free();
}

IOReturn
AppleVirtMeshSharedMemory::create_assignment(uint64_t offset, MainClient::MeshDirection direction, ConfigClient::NodeId node_id)
{
	DEV_LOG(_logger, "Creating assignment offset [0x%llx] direction [%u] node_id [%u]", offset, direction, node_id);

	AppleVirtMeshAssignment * curr_assignment = nullptr;

	auto res = get_assignment(offset, curr_assignment);
	if (kIOReturnSuccess == res) {
		/* Got an initialized assignment, and in VRE we should not re-initialize an object as in CIOMesh forwarder, because in VRE
		 * we do not support forwarder.
		 * TODO: Should it panic or return error? CIOMesh kext panics but I think return error would be better.
		 */
		os_log_error(_logger, "Creating a duplicated assignment at [%lld] is not allowed, not even forwarder, in VRE", offset);
		return kIOReturnBadArgument;
	}

	if (kIOReturnNotReady != res) {
		/* We should get an un-initialized assignment object indicated by kIOReturnNotReady, otherwise we should report this error.
		 */
		os_log_error(_logger, "Failed to get assignment at offset [%lld]", offset);
		return kIOReturnBadArgument;
	}

	auto curr_count = (direction == MainClient::MeshDirection::In) ? _incoming_assignments.count : _outgoing_assignments.count;
	if (curr_count >= kMaxAssignmentCount) {
		os_log_error(
		    _logger,
		    "Maxium number of %s assignements reached [%d]",
		    (MainClient::MeshDirection::In == direction) ? "incoming" : "outgoing",
		    curr_count
		);
		return kIOReturnInvalid;
	}

	auto new_assignment = AppleVirtMeshAssignment::allocate(this, direction);
	if (nullptr == new_assignment) {
		os_log_error(_logger, "Failed to create new assignment");
		return kIOReturnNoMemory;
	}

	if (MainClient::MeshDirection::In == direction) {
		new_assignment->set_rx_node(node_id);
		auto curr                          = _incoming_assignments.count;
		_incoming_assignments.node[curr]   = node_id;
		_incoming_assignments.offset[curr] = offset;
		_incoming_assignments.ready[curr]  = false;
		_incoming_assignments.count++;
		_incoming_assignments.remaining++;
	} else {
		auto curr                          = _outgoing_assignments.count;
		_outgoing_assignments.node[curr]   = node_id;
		_outgoing_assignments.offset[curr] = offset;
		_outgoing_assignments.count++;
		_outgoing_assignments.remaining++;
	}

	_assignments->replaceObject(get_index(offset), new_assignment);
	/* I think the following line is not needed because we are using OSSharedPtr */
	// OSSafeReleaseNULL(new_assignment); /* OSArray will retain it. */

	return kIOReturnSuccess;
}

IOReturn
AppleVirtMeshSharedMemory::get_assignment(uint64_t offset, AppleVirtMeshAssignment *& assignment)
{
	auto index = get_index(offset);
	return get_assignment_at_index(index, assignment);
}

IOReturn
AppleVirtMeshSharedMemory::get_assignment_at_index(uint64_t index, AppleVirtMeshAssignment *& assignment)
{
	if (index >= _assignments->getCount()) {
		os_log_error(_logger, "Assignment index [%llu] out of bound [%u]", index, _assignments->getCount());
		return kIOReturnInvalid;
	}

	/* Note: the object may be kOSBooleanFalse, so using OSRequiredCast here will cause panic or assertion fail that crashes the
	 * guest. Just use reinterpret_cast, check for kOSBoolealFalse and then OSRequiredCast it.
	 */
	assignment = static_cast<AppleVirtMeshAssignment *>(_assignments->getObject(index));

	/* Checking the nullptr seems safer vs checking the array count before getObject(). Because if the array is not locked, other
	 * code may change the array (e.g., removing an object) between the count check and getObject() thus we still get nullptr here.
	 * The current code seems safer although it does not guarantee atomicity either.
	 */
	if (nullptr == assignment) {
		os_log_error(_logger, "Cannot get assignment, potentially index [%llu] out of range [%u]", index, _assignments->getCount());
		return kIOReturnInvalid;
	}

	if (static_cast<void *>(assignment) == static_cast<void *>(kOSBooleanFalse)) {
		DEV_LOG(
		    _logger,
		    "Getting an uninitialized assignment at index [%llu], the caller function should handle this error.",
		    index
		);
		return kIOReturnNotReady;
	}

	assignment = OSRequiredCast(AppleVirtMeshAssignment, assignment);

	return kIOReturnSuccess;
}

unsigned int
AppleVirtMeshSharedMemory::get_index(uint64_t offset)
{
	auto     divisor = _assignment_size;
	uint64_t res     = offset / divisor;

	assertf(static_cast<uint64_t>(res) < UINT_MAX, "Offset index [%lld] out of bound", res);
	return static_cast<unsigned int>(res);
}
