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
//  Transaction.cpp
//  AppleCIOMesh
//
//  Created by Zixuan Wang on 11/18/24.
//

#include "VirtMesh/Guest/AppleVirtMeshIOBridge/Transaction.h"
#include "VirtMesh/Utils/Log.h"

using namespace VirtMesh::Guest::Bridge;

OSDefineMetaClassAndStructors(AppleVirtMeshIOTransaction, super);

OSSharedPtr<AppleVirtMeshIOTransaction>
AppleVirtMeshIOTransaction::transaction(void)
{
	auto transaction = OSMakeShared<AppleVirtMeshIOTransaction>();
	if (!transaction->super::init()) {
		return nullptr;
	}

	transaction->construct_logger();

	return transaction;
}

IOReturn
AppleVirtMeshIOTransaction::prepareBuffers(void)
{
	/* Either send-only or send-and-receive has to be initialized. I.e., the send descriptor has to be initialized. One transaction
	 * descriptor is only one direction. And to receive data, the send descriptor is used to notify the host, and the recv
	 * descriptor is used to get return data.
	 */
	DEV_LOG(_logger, "AppleVirtMeshIOTransaction::prepareBuffers()");
	if (!_send_desc) {
		os_log_error(_logger, "prepareBuffers() send descriptor [%016llx] does not exist.", (uint64_t)_send_desc.get());
		return kIOReturnError;
	}

	IOReturn res = kIOReturnSuccess;

	if (_send_desc) {
		res = _send_desc->prepare();
		if ((kIOReturnSuccess != res)) {
			os_log_error(_logger, "prepareBuffers() failed to prepare send descriptor: 0x%x", res);
			return kIOReturnNoMemory;
		}
	}

	if (_recv_desc) {
		res = _recv_desc->prepare();
		if ((kIOReturnSuccess != res)) {
			os_log_error(_logger, "prepareBuffers() failed to prepare recv descriptor: 0x%x", res);
			return kIOReturnNoMemory;
		}
	}

	return kIOReturnSuccess;
}

IOReturn
AppleVirtMeshIOTransaction::completeBuffers(void)
{
	DEV_LOG(_logger, "AppleVirtMeshIOTransaction::completeBuffers()");
	if (!_send_desc) {
		os_log_error(_logger, "Requires at least send descriptor to be provided");
		return kIOReturnError;
	}

	auto result = _send_desc->complete();
	if (kIOReturnSuccess != result) {
		os_log_error(_logger, "Failed to complete send desc");
		return result;
	}

	if (_recv_desc) {
		result = _recv_desc->complete();
		if (kIOReturnSuccess != result) {
			os_log_error(_logger, "Failed to complete send desc");
			return result;
		}
	}

	return kIOReturnSuccess;
}

IOByteCount
AppleVirtMeshIOTransaction::getBufferLength(void)
{
	DEV_LOG(_logger, "AppleVirtMeshIOTransaction::getBufferLength()");
	if (!_send_desc) {
		return 0;
	}

	auto length = _send_desc->getLength();
	DEV_LOG(_logger, "AppleVirtMeshIOTransaction::getBufferLength() send length [0x%llx]", length);

	if (_recv_desc) {
		DEV_LOG(_logger, "AppleVirtMeshIOTransaction::getBufferLength() recv length [0x%llx]", _recv_desc->getLength());
		length += _recv_desc->getLength();
	}

	DEV_LOG(_logger, "AppleVirtMeshIOTransaction::getBufferLength() length [0x%llx]", length);
	return length;
}

IOPhysicalAddress
AppleVirtMeshIOTransaction::getBufferSegment(IOByteCount offset, IOByteCount * length, bool * output)
{
	DEV_LOG(_logger, "AppleVirtMeshIOTransaction::getBufferSegment() offset [0x%llx]", offset);
	IOPhysicalAddress result = 0;

	if (!_send_desc) {
		return 0;
	}

	if (offset < _send_desc->getLength()) {
		/* Pure outgoing buffer to the host */
		*output = true;
		result  = _send_desc->getPhysicalSegment(offset, length);
	} else {
		offset -= _send_desc->getLength();
		if (offset < _recv_desc->getLength()) {
			/* Pure incoming buffer from the host */
			*output = false;
			result  = _recv_desc->getPhysicalSegment(offset, length);
		}
	}

	return result;
}

bool
AppleVirtMeshIOTransaction::decodeMessage(Message * message)
{
	DEV_LOG(_logger, "AppleVirtMeshIOTransaction::decodeMessage()");
	if (!_recv_desc) {
		os_log_error(_logger, "Recv descriptor is null");
		return false;
	}

	if (!message->decode(_recv_desc->getBytesNoCopy(), _recv_desc->getLength())) {
		os_log_error(_logger, "Failed to decode message from descriptor");
		return false;
	}

	return true;
}

bool
AppleVirtMeshIOTransaction::encodeMessage(const Message * message, bool is_send_only)
{
	auto message_size = message->size();
	DEV_LOG(_logger, "AppleVirtMeshIOTransaction::encodeMessage() size [0x%llx] is_send_only [%u]", message->size(), is_send_only);

	/* NOTE: although the option is set to be Out or InOut, the AppleVirtIO still requires the use of two distinct descriptors--one
	 * for send and on for receive--to receive data from host. Thus we initialize both descriptors if we request to receive a data.
	 * For send-only we only need to initialize the send descriptor.
	 */
	IOOptionBits option = kIOMemoryKernelUserShared;
	if (is_send_only) {
		option |= kIOMemoryDirectionOut;
	} else {
		option |= kIOMemoryDirectionInOut;
	}

	_send_desc = IOBufferMemoryDescriptor::withOptions(option, message_size);

	if (!is_send_only) {
		_recv_desc = IOBufferMemoryDescriptor::withOptions(option, message_size);
	}

	auto send_size = _send_desc->getLength();
	DEV_LOG(_logger, "AppleVirtMeshIOTransaction::encodeMessage() send_size [0x%llx]", send_size);
	if (!message->encode(_send_desc->getBytesNoCopy(), &send_size)) {
		os_log_error(_logger, "Failed to encode message to descriptor");
		return false;
	}

	_send_desc->setLength(send_size);

	return true;
}
