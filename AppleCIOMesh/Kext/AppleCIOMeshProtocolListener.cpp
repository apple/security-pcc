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

#include "AppleCIOMeshProtocolListener.h"

#include "Common/Config.h"
#include "Util/Error.h"
#include "Util/ReturnCode.h"

OSDefineMetaClassAndStructors(AppleCIOMeshProtocolListener, OSObject);

AppleCIOMeshProtocolListener *
AppleCIOMeshProtocolListener::withLocalNode(IOThunderboltLocalNode * localNode)
{
	auto me = OSTypeAlloc(AppleCIOMeshProtocolListener);
	if (me != nullptr && me->initLocalNode(localNode)) {
		return me;
	}
	OSSafeReleaseNULL(me);
	return nullptr;
}

bool
AppleCIOMeshProtocolListener::initLocalNode(IOThunderboltLocalNode * localNode)
{
	_localNode = localNode;

	_controller = _localNode->getController();
	RETURN_IF_NULL(_controller, false, "cast controller");

	// Set up a listener
	_controlPath = _controller->getControlPath();
	RETURN_IF_NULL(_controlPath, false, "get control path");

	_xdListener = IOThunderboltProtocolListener::withController(_controller);
	RETURN_IF_NULL(_xdListener, false, "create protocol listener");

	IOReturn status;

	// FIXME: Where can we include EFI_GUID from?
	struct EFI_GUID {
		uint32_t Data1;
		uint16_t Data2;
		uint16_t Data3;
		uint8_t Data4[8];
	};

	// Generated via `uuidgen`; the value is random and has no significance.
	const EFI_GUID guid{0xE7E36398, 0x7844, 0x464F, 0x8F, 0x7d, 0xAC, 0x70, 0xA2, 0xE8, 0x82, 0x5A};
	uuid_t uuid = {0};
	memcpy(uuid, &guid, sizeof(EFI_GUID));
	status = _xdListener->setProtocolUUID(uuid);
	RETURN_IF_FAIL(status, false, "set protocol uuid");

	_controlPath->addListener(_xdListener);
	_published = false;

	return true;
}

bool
AppleCIOMeshProtocolListener::publish()
{
	if (_published) {
		return true;
	}

	// Publish the service
	ThunderboltXDPropertiesEntryKey protocolKey{XD_PROTOCOL_KEY_STRING};
	const auto protocolId       = 1;
	const auto protocolVersion  = 1;
	const auto protocolRevision = 1;
	uint32_t settings           = 0;
	auto status = _localNode->publishXDService(protocolKey, protocolId, protocolVersion, protocolRevision, settings);
	RETURN_IF_FAIL(status, false, "publish xd service");

	_published = true;
	return true;
}

bool
AppleCIOMeshProtocolListener::unpublish()
{
	if (!_published) {
		return true;
	}

	ThunderboltXDPropertiesEntryKey protocolKey{XD_PROTOCOL_KEY_STRING};
	auto status = _localNode->unpublishXDService(protocolKey);

	RETURN_IF_FAIL(status, false, "unpublish xd service");

	_published = false;
	return true;
}
