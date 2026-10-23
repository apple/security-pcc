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
#include "plan.h"

#include <AppleCIOMeshSupport/AppleCIOMeshAPI.h>

#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static MeshBufferState_t *
getMBSByBufferId(MeshBufferSet_t * allsets, uint64_t len, uint32_t id)
{
	for (size_t i = 0; i < len; ++i) {
		if (allsets[i].bufferId == id) {
			return allsets[i].mbs;
		}
	}
	return nullptr;
}
namespace
{
struct SendToAllBufferDetails {
	SendToAllBufferDescription const * description;
	void * userBuffer;
};
} // namespace

static SendToAllBufferDetails const *
getSendToAllDescription(std::vector<SendToAllBufferDetails> const & details, uint64_t bufferId)
{
	for (auto && item : details) {
		if (item.description->bufferId == bufferId) {
			return &item;
		}
	}
	return nullptr;
}

int
smoke_test_main(int argc, char * argv[])
{
	if (argc != 2) {
		puts("Usage: llmsim -smoketest <json plan file>");
		exit(1);
	}

	const char * planFile = argv[1];
	uint32_t node;
	uint32_t numNodes;
	bool meshInfoStatus = ::MeshGetInfo(&node, &numNodes);
	assert(meshInfoStatus);

	const char * defaultCryptoKey = "123456789abcdef0123456789abcdef0";
	MeshSetCryptoKey(defaultCryptoKey, strlen(defaultCryptoKey));

	auto mh = MeshCreateHandle(0);
	assert(mh && "Mesh failed to create");

	auto opt_plan = populatePlan(planFile, node);
	if (!opt_plan) {
		puts("Failed to populate plan");
		exit(1);
	}

	auto simPlan = opt_plan.value();
	std::vector<SendToAllBufferDetails> s2aDetails;
	// Setup SendToAll buffers
	for (auto && s2aBuffer : simPlan.sendToAllBuffers) {
		void * userBuffer = nullptr;
		auto ret          = posix_memalign((void **)&userBuffer, 0x4000, s2aBuffer.bufferSize);
		assert(ret == 0);
		memset(userBuffer, 0xcc, s2aBuffer.bufferSize);
		ret = MeshSetupSendToAllBufferEx(mh, s2aBuffer.mask, s2aBuffer.bufferId, userBuffer, s2aBuffer.bufferSize);
		assert(ret == 0);
		s2aDetails.push_back({&s2aBuffer, userBuffer});
	}

	// Setup BaG buffers
	const auto bufferSetsLen = simPlan.bufferSets.size();
	auto * allsets           = new MeshBufferSet_t[bufferSetsLen];
	for (size_t i = 0; i < bufferSetsLen; ++i) {
		auto & bufferset = simPlan.bufferSets[i];
		auto * buffers   = new void *[bufferset.bufferCount];
		for (size_t j = 0; j < bufferset.bufferCount; ++j) {
			buffers[j] = nullptr;
			int ret    = posix_memalign((void **)&buffers[j], 0x4000, bufferset.bufferSize);
			assert(ret == 0);
		}
		allsets[i].bufferId   = bufferset.bufferId;
		allsets[i].bufferSize = bufferset.bufferSize;
		allsets[i].bufferPtrs = buffers;
		allsets[i].numBuffers = bufferset.bufferCount;
		allsets[i].nodeMask   = bufferset.mask;
	}

	auto ret = MeshSetupBufferEx(mh, allsets, (uint16_t)bufferSetsLen);
	assert(ret == 0);

	printf("Executing '%s'\n", simPlan.name.c_str());

	srand(node);
	constexpr auto kMaxJitterUs = 30'000u;

	for (auto const & plan : simPlan.execPlans) {
		MeshBufferState_t * mbs = getMBSByBufferId(allsets, bufferSetsLen, plan.bufferId);
		if (mbs) {
			MeshAssignBuffersToReaders(mh, mbs, plan.syncCount);
			unsigned delay = (unsigned)rand() % kMaxJitterUs;
			usleep(delay);
			for (unsigned j = 0; j < plan.syncCount; ++j) {
				ret = MeshBroadcastAndGather(mh, mbs);
				printf("BufferId %u - Iteration %u: %s\n", plan.bufferId, j + 1, ret == 0 ? "Success" : "Failed");
				delay = (unsigned)rand() % kMaxJitterUs;
				assert(ret == 0);
			}
		} else {
			SendToAllBufferDetails const * details = getSendToAllDescription(s2aDetails, plan.bufferId);
			assert(details != nullptr);
			const uint32_t leaderNodeId = (uint32_t)__builtin_ctzll(details->description->mask);
			if (node == leaderNodeId) {
				ret = MeshSendToAllPeers(mh, plan.bufferId, details->userBuffer, details->description->bufferSize);
				printf("Sending BufferId %u to 0x%llx: %s\n", plan.bufferId, details->description->mask,
				       ret ? "Success" : "Failed");
				assert(ret == true);
			} else {
				ret = MeshReceiveFromLeaderEx(mh, leaderNodeId, plan.bufferId, details->userBuffer,
				                              details->description->bufferSize, 0);
				printf("Receiving BufferId %u from %u: %s\n", plan.bufferId, leaderNodeId, ret ? "Success" : "Failed");
				assert(ret == true);
			}
		}
	}

	for (size_t i = 0; i < bufferSetsLen; ++i) {
		MeshReleaseBuffers(mh, allsets[i].mbs);
		/*** No reason to free the user buffers, process is exiting ***/
	}

	for (auto && s2aBuffer : simPlan.sendToAllBuffers) {
		MeshReleaseBuffer(mh, s2aBuffer.bufferId, s2aBuffer.bufferSize);
	}
	MeshDestroyHandle(mh);

	printf("'%s' executed successfully\n", simPlan.name.c_str());
	return 0;
}
