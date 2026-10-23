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

#include "plan.h"

#include "json.h"

#include <optional>
#include <string>
#include <string_view>
#include <vector>

using namespace llmsim;

static std::optional<Json>
read_file(const char * filename)
{
	FILE * file = fopen(filename, "r");
	if (!file) {
		printf("Failed to open file %s\n", filename);
		return std::nullopt;
	}
	fseek(file, 0, SEEK_END);
	size_t file_size = ftell(file);
	fseek(file, 0, SEEK_SET);
	char * buffer = (char *)malloc(file_size);
	fread(buffer, 1, file_size, file);
	fclose(file);

	std::optional<Json> json_opt = Json::parse(buffer);
	if (!json_opt) {
		free(buffer);
		return std::nullopt;
	}
	return json_opt;
}

static uint64_t
fromHumanToBytes(std::string_view size)
{
	size_t pos     = 0;
	uint64_t value = std::stoull(std::string(size), &pos);
	if (pos == size.length()) {
		return value;
	}
	if (size[pos] == 'K' || size[pos] == 'k') {
		return value * 1024;
	}
	if (size[pos] == 'M' || size[pos] == 'm') {
		return value * 1024 * 1024;
	}
	if (size[pos] == 'G' || size[pos] == 'g') {
		return value * 1024 * 1024 * 1024;
	}
	return 0;
}

static uint64_t
fromHex(std::string_view size)
{
	size_t pos     = 0;
	uint64_t value = std::stoull(std::string(size), &pos, 16);
	if (pos == size.length()) {
		return value;
	}
	return 0;
}

static uint64_t
getP2pCioMask(uint32_t myNodeId)
{
	switch (myNodeId) {
	case 0:
	case 1:
		return 0x3;
	case 2:
	case 3:
		return 0xC;
	case 4:
	case 5:
		return 0x30;
	case 6:
	case 7:
		return 0xC0;
	case 8:
	case 9:
		return 0x300;
	case 10:
	case 11:
		return 0xC00;
	case 12:
	case 13:
		return 0x3000;
	case 14:
	case 15:
		return 0xC000;
	default:
		printf("Invalid node id %d\n", myNodeId);
		abort();
	}
}
static uint64_t
getP2pNetMask(uint32_t myNodeId)
{
	switch (myNodeId) {
	case 0:
	case 8:
		return 0x101;
	case 1:
	case 9:
		return 0x202;
	case 2:
	case 10:
		return 0x404;
	case 3:
	case 11:
		return 0x808;
	case 4:
	case 12:
		return 0x1010;
	case 5:
	case 13:
		return 0x2020;
	case 6:
	case 14:
		return 0x4040;
	case 7:
	case 15:
		return 0x8080;
	default:
		printf("Invalid node id %d\n", myNodeId);
		abort();
	}
}

// Populates a llmsim plan from a file.
std::optional<SimPlan>
populatePlan(const char * filename, uint32_t myNodeId)
{
	auto json_opt = read_file(filename);
	if (!json_opt) {
		return std::nullopt;
	}
	Json & json = json_opt.value();
	std::string simPlanName{json["PlanName"].string()};
	auto & buffSetDescJson = json["BufferSetDescriptions"];
	auto len               = buffSetDescJson.length();
	std::vector<BufferSetDescription> buffersetDescriptions;
	buffersetDescriptions.reserve(len);
	for (size_t i = 0; i < len; i++) {
		auto & set = buffSetDescJson[i];
		BufferSetDescription desc;
		desc.bufferId    = (uint32_t)set["bufferId"].integer();
		desc.bufferCount = (uint32_t)set["bufferCount"].integer();
		desc.bufferSize  = fromHumanToBytes(set["bufferSize"].string());
		auto mask        = set["mask"].string();
		if (mask == "p2p-net") {
			desc.mask = getP2pNetMask(myNodeId);
		} else if (mask == "p2p-cio") {
			desc.mask = getP2pCioMask(myNodeId);
		} else if (mask == "partition") {
			desc.mask = myNodeId > 7 ? 0xFF00 : 0xFF;
		} else {
			desc.mask = fromHex(mask);
		}
		buffersetDescriptions.push_back(desc);
	}

	// parse the send to all buffers
	std::vector<SendToAllBufferDescription> sendToAllBuffers;
	if (json.has_key("SendToAllBufferDescriptions")) {
		len = json["SendToAllBufferDescriptions"].length();
		sendToAllBuffers.reserve(len);
		auto & sendToAllBufferJson = json["SendToAllBufferDescriptions"];
		for (size_t i = 0; i < len; i++) {
			auto const & ithBuffer = sendToAllBufferJson[i];
			SendToAllBufferDescription result;
			result.bufferId   = (uint32_t)ithBuffer["bufferId"].integer();
			result.bufferSize = fromHumanToBytes(ithBuffer["bufferSize"].string());
			auto mask         = ithBuffer["mask"].string();
			if (mask == "partition") {
				result.mask = myNodeId > 7 ? 0xFF00 : 0xFF;
			} else {
				result.mask = fromHex(mask);
			}
			sendToAllBuffers.push_back(result);
		}
		// Perform a sanity check to ensure buffer Ids do not overlap with BufferSetDescriptions
		for (auto const & bufferSet : buffersetDescriptions) {
			for (auto const & sendToAllBuffer : sendToAllBuffers) {
				if (bufferSet.bufferId == sendToAllBuffer.bufferId) {
					printf("Buffer Id %d is used in both BufferSetDescriptions and SendToAllBufferDescriptions\n",
					       bufferSet.bufferId);
					return std::nullopt;
				}
			}
		}
	}

	// parse the ExecutionPlan
	auto const & execPlanJson = json["ExecutionPlan"];
	len                       = execPlanJson.length();
	std::vector<ExecPlan> execPlans;
	execPlans.reserve(len);
	for (size_t i = 0; i < len; i++) {
		auto const & ithPlan = execPlanJson[i];
		ExecPlan result;
		result.bufferId = (uint32_t)ithPlan["bufferId"].integer();
		if (ithPlan.has_key("syncCount")) {
			result.syncCount = (uint32_t)ithPlan["syncCount"].integer();
		} else {
			// SendToAllBuffers are broadcasted only once.
			// syncCount is ignored in this case.
			result.syncCount = 0;
		}
		execPlans.push_back(result);
	}

	return SimPlan{simPlanName, buffersetDescriptions, sendToAllBuffers, execPlans};
}
