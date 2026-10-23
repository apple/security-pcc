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
//  TestEnsembleMap.mm
//  AppleCIOMesh
//
//  Created by Ria Paul on 11/5/24.
//

#include <AppleCIOMeshSupport/AppleCIOMeshAPI.h>
#include <AppleCIOMeshSupport/AppleCIOMeshAPIPrivate.h>
#include <cassert>
#include <stdint.h>

#define COST(map, src, dst) map->route_cost[src * map->node_count + dst]

void
verifyMap2(MeshEnsembleMap_t * map)
{
	assert(COST(map, 0, 0) == 0);
	assert(COST(map, 0, 1) == CioHop);
	assert(COST(map, 1, 1) == 0);
	assert(COST(map, 1, 0) == CioHop);
}

void
verifyChassis0(MeshEnsembleMap_t * map)
{
	uint32_t * route_cost = map->route_cost;
	assert(COST(map, 0, 0) == 0);
	assert(COST(map, 0, 1) == CioHop);
	assert(COST(map, 0, 2) == CioHop);
	assert(COST(map, 0, 3) == CioHop);
	assert(COST(map, 1, 0) == CioHop);
	assert(COST(map, 1, 1) == 0);
	assert(COST(map, 1, 2) == CioHop);
	assert(COST(map, 1, 3) == CioHop);
	assert(COST(map, 2, 0) == CioHop);
	assert(COST(map, 2, 1) == CioHop);
	assert(COST(map, 2, 2) == 0);
	assert(COST(map, 2, 3) == CioHop);
	assert(COST(map, 3, 0) == CioHop);
	assert(COST(map, 3, 1) == CioHop);
	assert(COST(map, 3, 2) == CioHop);
	assert(COST(map, 3, 3) == 0);
}

void
verifyChassis1(MeshEnsembleMap_t * map)
{
	uint32_t * route_cost = map->route_cost;
	assert(COST(map, 4, 4) == 0);
	assert(COST(map, 4, 5) == CioHop);
	assert(COST(map, 4, 6) == CioHop);
	assert(COST(map, 4, 7) == CioHop);
	assert(COST(map, 5, 4) == CioHop);
	assert(COST(map, 5, 5) == 0);
	assert(COST(map, 5, 6) == CioHop);
	assert(COST(map, 5, 7) == CioHop);
	assert(COST(map, 6, 4) == CioHop);
	assert(COST(map, 6, 5) == CioHop);
	assert(COST(map, 6, 6) == 0);
	assert(COST(map, 6, 7) == CioHop);
	assert(COST(map, 7, 4) == CioHop);
	assert(COST(map, 7, 5) == CioHop);
	assert(COST(map, 7, 6) == CioHop);
	assert(COST(map, 7, 7) == 0);
}

void
verifyChassis2(MeshEnsembleMap_t * map)
{
	uint32_t * route_cost = map->route_cost;
	assert(COST(map, 8, 8) == 0);
	assert(COST(map, 8, 9) == CioHop);
	assert(COST(map, 8, 10) == CioHop);
	assert(COST(map, 8, 11) == CioHop);
	assert(COST(map, 9, 8) == CioHop);
	assert(COST(map, 9, 9) == 0);
	assert(COST(map, 9, 10) == CioHop);
	assert(COST(map, 9, 11) == CioHop);
	assert(COST(map, 10, 8) == CioHop);
	assert(COST(map, 10, 9) == CioHop);
	assert(COST(map, 10, 10) == 0);
	assert(COST(map, 10, 11) == CioHop);
	assert(COST(map, 11, 8) == CioHop);
	assert(COST(map, 11, 9) == CioHop);
	assert(COST(map, 11, 10) == CioHop);
	assert(COST(map, 11, 11) == 0);
}

void
verifyChassis3(MeshEnsembleMap_t * map)
{
	uint32_t * route_cost = map->route_cost;
	assert(COST(map, 12, 12) == 0);
	assert(COST(map, 12, 13) == CioHop);
	assert(COST(map, 12, 14) == CioHop);
	assert(COST(map, 12, 15) == CioHop);
	assert(COST(map, 13, 12) == CioHop);
	assert(COST(map, 13, 13) == 0);
	assert(COST(map, 13, 14) == CioHop);
	assert(COST(map, 13, 15) == CioHop);
	assert(COST(map, 14, 12) == CioHop);
	assert(COST(map, 14, 13) == CioHop);
	assert(COST(map, 14, 14) == 0);
	assert(COST(map, 14, 15) == CioHop);
	assert(COST(map, 15, 12) == CioHop);
	assert(COST(map, 15, 13) == CioHop);
	assert(COST(map, 15, 14) == CioHop);
	assert(COST(map, 15, 15) == 0);
}

void
verifyPartition1(MeshEnsembleMap_t * map)
{
	verifyChassis0(map);
	verifyChassis1(map);

	// validate costs from chassis 0 to 1
	assert(COST(map, 0, 4) == CioHop);
	assert(COST(map, 0, 5) == 2 * CioHop);
	assert(COST(map, 0, 6) == 2 * CioHop);
	assert(COST(map, 0, 7) == 2 * CioHop);
	assert(COST(map, 1, 4) == 2 * CioHop);
	assert(COST(map, 1, 5) == CioHop);
	assert(COST(map, 1, 6) == 2 * CioHop);
	assert(COST(map, 1, 7) == 2 * CioHop);
	assert(COST(map, 2, 4) == 2 * CioHop);
	assert(COST(map, 2, 5) == 2 * CioHop);
	assert(COST(map, 2, 6) == CioHop);
	assert(COST(map, 2, 7) == 2 * CioHop);
	assert(COST(map, 3, 4) == 2 * CioHop);
	assert(COST(map, 3, 5) == 2 * CioHop);
	assert(COST(map, 3, 6) == 2 * CioHop);
	assert(COST(map, 3, 7) == CioHop);

	// validate costs from chassis 1 to chassis 0
	assert(COST(map, 4, 0) == CioHop);
	assert(COST(map, 4, 1) == 2 * CioHop);
	assert(COST(map, 4, 2) == 2 * CioHop);
	assert(COST(map, 4, 3) == 2 * CioHop);
	assert(COST(map, 5, 0) == 2 * CioHop);
	assert(COST(map, 5, 1) == CioHop);
	assert(COST(map, 5, 2) == 2 * CioHop);
	assert(COST(map, 5, 3) == 2 * CioHop);
	assert(COST(map, 6, 0) == 2 * CioHop);
	assert(COST(map, 6, 1) == 2 * CioHop);
	assert(COST(map, 6, 2) == CioHop);
	assert(COST(map, 6, 3) == 2 * CioHop);
	assert(COST(map, 7, 0) == 2 * CioHop);
	assert(COST(map, 7, 1) == 2 * CioHop);
	assert(COST(map, 7, 2) == 2 * CioHop);
	assert(COST(map, 7, 3) == CioHop);
}

void
verifyPartition2(MeshEnsembleMap_t * map)
{
	verifyChassis2(map);
	verifyChassis3(map);
}

void
verifyMap4(MeshEnsembleMap_t * map)
{
	verifyChassis0(map);
}

void
verifyMap8(MeshEnsembleMap_t * map)
{
	verifyPartition1(map);
}

void
verifyMap16(MeshEnsembleMap_t * map)
{
	verifyPartition1(map);
	verifyPartition2(map);

	// SOC 0 to chassis 2 and chassis 3
	assert(COST(map, 0, 8) == NetworkHop);
	assert(COST(map, 0, 9) == NetworkHop + CioHop);
	assert(COST(map, 0, 10) == NetworkHop + CioHop);
	assert(COST(map, 0, 11) == NetworkHop + CioHop);
	assert(COST(map, 0, 12) == NetworkHop + CioHop);
	assert(COST(map, 0, 13) == NetworkHop + (2 * CioHop));
	assert(COST(map, 0, 14) == NetworkHop + (2 * CioHop));
	assert(COST(map, 0, 15) == NetworkHop + (2 * CioHop));

	assert(COST(map, 1, 8) == NetworkHop + CioHop);
	assert(COST(map, 1, 9) == NetworkHop);
	assert(COST(map, 1, 10) == NetworkHop + CioHop);
	assert(COST(map, 1, 11) == NetworkHop + CioHop);
	assert(COST(map, 1, 12) == NetworkHop + (2 * CioHop));
	assert(COST(map, 1, 13) == NetworkHop + CioHop);
	assert(COST(map, 1, 14) == NetworkHop + (2 * CioHop));
	assert(COST(map, 1, 15) == NetworkHop + (2 * CioHop));

	assert(COST(map, 2, 8) == NetworkHop + CioHop);
	assert(COST(map, 2, 9) == NetworkHop + CioHop);
	assert(COST(map, 2, 10) == NetworkHop);
	assert(COST(map, 2, 11) == NetworkHop + CioHop);
	assert(COST(map, 2, 12) == NetworkHop + (2 * CioHop));
	assert(COST(map, 2, 13) == NetworkHop + (2 * CioHop));
	assert(COST(map, 2, 14) == NetworkHop + CioHop);
	assert(COST(map, 2, 15) == NetworkHop + (2 * CioHop));

	assert(COST(map, 3, 8) == NetworkHop + CioHop);
	assert(COST(map, 3, 9) == NetworkHop + CioHop);
	assert(COST(map, 3, 10) == NetworkHop + CioHop);
	assert(COST(map, 3, 11) == NetworkHop);
	assert(COST(map, 3, 12) == NetworkHop + (2 * CioHop));
	assert(COST(map, 3, 13) == NetworkHop + (2 * CioHop));
	assert(COST(map, 3, 14) == NetworkHop + (2 * CioHop));
	assert(COST(map, 3, 15) == NetworkHop + CioHop);

	assert(COST(map, 4, 8) == NetworkHop + CioHop);
	assert(COST(map, 4, 9) == NetworkHop + (2 * CioHop));
	assert(COST(map, 4, 10) == NetworkHop + (2 * CioHop));
	assert(COST(map, 4, 11) == NetworkHop + (2 * CioHop));
	assert(COST(map, 4, 12) == NetworkHop);
	assert(COST(map, 4, 13) == NetworkHop + CioHop);
	assert(COST(map, 4, 14) == NetworkHop + CioHop);
	assert(COST(map, 4, 15) == NetworkHop + CioHop);

	assert(COST(map, 5, 8) == NetworkHop + (2 * CioHop));
	assert(COST(map, 5, 9) == NetworkHop + CioHop);
	assert(COST(map, 5, 10) == NetworkHop + (2 * CioHop));
	assert(COST(map, 5, 11) == NetworkHop + (2 * CioHop));
	assert(COST(map, 5, 12) == NetworkHop + CioHop);
	assert(COST(map, 5, 13) == NetworkHop);
	assert(COST(map, 5, 14) == NetworkHop + CioHop);
	assert(COST(map, 5, 15) == NetworkHop + CioHop);

	assert(COST(map, 6, 8) == NetworkHop + (2 * CioHop));
	assert(COST(map, 6, 9) == NetworkHop + (2 * CioHop));
	assert(COST(map, 6, 10) == NetworkHop + CioHop);
	assert(COST(map, 6, 11) == NetworkHop + (2 * CioHop));
	assert(COST(map, 6, 12) == NetworkHop + CioHop);
	assert(COST(map, 6, 13) == NetworkHop + CioHop);
	assert(COST(map, 6, 14) == NetworkHop);
	assert(COST(map, 6, 15) == NetworkHop + CioHop);

	assert(COST(map, 7, 8) == NetworkHop + (2 * CioHop));
	assert(COST(map, 7, 9) == NetworkHop + (2 * CioHop));
	assert(COST(map, 7, 10) == NetworkHop + (2 * CioHop));
	assert(COST(map, 7, 11) == NetworkHop + CioHop);
	assert(COST(map, 7, 12) == NetworkHop + CioHop);
	assert(COST(map, 7, 13) == NetworkHop + CioHop);
	assert(COST(map, 7, 14) == NetworkHop + CioHop);
	assert(COST(map, 7, 15) == NetworkHop);
}

int
main(int argc, char ** argv)
{
	if (argc < 2 || argc > 3) {
		printf("Usage:\n");
		printf("TestEnsembleMap -nodecount <node count>\n");
		return 1;
	}

	if (strcmp(argv[1], "-nodecount") != 0) {
		printf("Usage:\n");
		printf("TestEnsembleMap -nodecount <node count>\n");
		return 1;
	}

	if (argc == 2) {
		// no node count was passed in, so run all tests
		MeshEnsembleMap_t * map_2 = MeshGetEnsembleMap(2);
		verifyMap2(map_2);
		printf("validated map of 2 nodes.\n");

		MeshEnsembleMap_t * map_4 = MeshGetEnsembleMap(4);
		verifyMap4(map_4);
		printf("validated map of 4 nodes.\n");

		MeshEnsembleMap_t * map_8 = MeshGetEnsembleMap(8);
		verifyMap8(map_8);
		printf("validated map of 8 nodes.\n");

		MeshEnsembleMap_t * map_16 = MeshGetEnsembleMap(16);
		verifyMap16(map_16);
		printf("validated map of 16 nodes.\n");
	} else {
		uint32_t nodeCount = (uint32_t)atoi(argv[2]);

		if (nodeCount == 2) {
			MeshEnsembleMap_t * map_2 = MeshGetEnsembleMap(2);
			verifyMap2(map_2);
			printf("validated map of 2 nodes.\n");
		} else if (nodeCount == 4) {
			MeshEnsembleMap_t * map_4 = MeshGetEnsembleMap(4);
			verifyMap4(map_4);
			printf("validated map of 4 nodes.\n");
		} else if (nodeCount == 8) {
			MeshEnsembleMap_t * map_8 = MeshGetEnsembleMap(8);
			verifyMap8(map_8);
			printf("validated map of 8 nodes.\n");
		} else if (nodeCount == 16) {
			MeshEnsembleMap_t * map_16 = MeshGetEnsembleMap(16);
			verifyMap16(map_16);
			printf("validated map of 16 nodes.\n");
		} else {
			printf("Invalid node count passed in.\n");
			return 1;
		}
	}

	return 0;
}
