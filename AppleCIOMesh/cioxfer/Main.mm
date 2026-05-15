// Copyright © 2025 Apple Inc. All Rights Reserved.

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
//
// cioxfer - a program to quickly distribute a file from 1 compute node to
// multiple compute nodes via CIO Mesh.
//

#include <AssertMacros.h>
#import <Foundation/Foundation.h>
#include <ctype.h>
#include <err.h>
#include <mach/mach_time.h>
#include <math.h>
#include <os/log.h>
#include <os/signpost_private.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <sysexits.h>
#include <unistd.h>

extern "C" {
#include <corecrypto/ccmode.h>
}

#include <IOKit/IOKitLib.h>
#include <IOReport.h>

#import <AppleCIOMeshConfigSupport/AppleCIOMeshConfigSupport.h>
#import <AppleCIOMeshSupport/AppleCIOMeshAPI.h>
#import <AppleCIOMeshSupport/AppleCIOMeshAPIPrivate.h>
#import <AppleCIOMeshSupport/AppleCIOMeshSupport.h>

static os_log_t logHandle = os_log_create("com.apple.cioxfer", "signpost");
#define kNsPerSecond (1000000000.0)

typedef struct {
	char fileName[256];
	uint64_t fileSize;
} FileMeta;

static void
usage(char * name)
{
	fprintf(stderr, "usage:\n");
	fprintf(stderr, "\t%s [file]\n", name);
	fprintf(stderr, "\t Node0 will send the file to everyone else.");
	fprintf(stderr,
	        "options: set environment variable MESH_CRYPTO=1 to enable encryption\n"
	        "         env var MESH_VERBOSE=1 for extremely verbose logging.\n");
}

MeshHandle_t * global_mh = NULL; // only for the signal handler

void
cioxfer_SigIntHandler(int)
{
	if (global_mh) {
		printf("SIGINT!!!!\n");
		MeshStopReaders(global_mh);
	}
	exit(1);
}

const uint32_t fileTransferBufferIdBase = 0x1000;
const uint32_t fileTransferBufferSize   = 4 * 1024 * 1024;
const uint32_t fileTransferBufferCount  = 4;
void ** fileTransferBufferPtrs;
constexpr uint32_t leaderNodeId = 0;

const uint32_t fileMetaBufferId   = 0x2000;
const uint32_t fileMetaBufferSize = 16 * 1024;
void * fileMetaBuffer;
dispatch_semaphore_t bufferSem[fileTransferBufferCount];

static void *
allocateBuffer(uint64_t bufferSize)
{
	uint8_t * buffer = (uint8_t*)malloc(bufferSize);
    if (buffer == NULL) {
        fprintf(stderr, "malloc failed for %llu bytes, errno: %d (%s)\n",
            bufferSize, errno, strerror(errno));
		return NULL;
	};
	// make sure all the memory is present so that the cost of faulting
	// in the pages isn't paid for by other code.
	memset(buffer, 0xa5, bufferSize);

	return buffer;
}

int
main(int argc, char ** argv)
{
	char * file = nullptr;
	int fd;
	uint64_t fileSize = 0;
	FileMeta fileMeta;

	MeshHandle_t * mh;

	if (argc != 2) {
		usage(argv[0]);
		exit(1);
	}

	file = argv[1];

	printf("Using :: %s\n", file);

	uint32_t myNodeId, nodeCount;

	if (!MeshGetInfo(&myNodeId, &nodeCount)) {
		printf("Could not get basic info about my node-id or the number of nodes.  Fail.\n");
		exit(1);
	}

	const uint64_t nodeMask = (1ull << nodeCount) - 1;

	const char * defaultCryptoKey = "123456789abcdef0123456789abcdef0";
	printf("Using default crypto key '%s'\n", defaultCryptoKey);
	MeshSetCryptoKey(defaultCryptoKey, strlen(defaultCryptoKey));

	mh = MeshCreateHandle(MESH_DEFAULT_LEADER_NODE_ID);
	if (!mh) {
		printf("Could not setup the mesh.\n");
		exit(2);
	}

	if (getenv("MESH_CRYPTO") != NULL) {
		static const char * key = "123456789abcdef0";
		printf("Setting crypto key\n");
		MeshSetCryptoKey(key, strlen(key));
	}

	global_mh = mh; // only for the sigint handler
	signal(SIGINT, cioxfer_SigIntHandler);

	MeshClaim(mh);

	MeshSetMaxTimeout(mh, 0);

	fileMetaBuffer = allocateBuffer(fileMetaBufferSize);
	if (fileMetaBuffer == NULL) {
		printf("no memory for the send-to-all file meta buffer.\n");
		exit(3);
	}

	fileTransferBufferPtrs = (void **)calloc(fileTransferBufferCount, sizeof(void *));
	if (fileTransferBufferPtrs == NULL) {
		printf("No memory for file transfer buffer pointers\n");
		exit(1);
	}

	for (uint32_t i = 0; i < fileTransferBufferCount; i++) {
		fileTransferBufferPtrs[i] = allocateBuffer(fileTransferBufferSize);
		if (fileTransferBufferPtrs[i] == NULL) {
			printf("No memory for fileTransferBufferPtrs[%d]\n", i);
			exit(1);
		}
	}

	dispatch_queue_t copyWorkerQueue = dispatch_queue_create("copyWorkerQueue", DISPATCH_QUEUE_SERIAL);
	dispatch_group_t group           = dispatch_group_create();

	MeshSetupSendToAllBufferEx(mh, nodeMask, fileMetaBufferId, fileMetaBuffer, fileMetaBufferSize);
	for (uint32_t i = 0; i < fileTransferBufferCount; i++) {
		MeshSetupSendToAllBufferEx(mh, nodeMask, fileTransferBufferIdBase + i, fileTransferBufferPtrs[i], fileTransferBufferSize);
	}

	if (myNodeId == MESH_DEFAULT_LEADER_NODE_ID) {
		fd = open(file, O_RDONLY);
		if (fd < 0) {
			printf("Cannot open %s for reading\n", file);
			exit(1);
		}

		struct stat fdStat;
		if (fstat(fd, &fdStat) < 0) {
			printf("Could not fstat %s\n", file);
			exit(1);
		}

		fileSize = (uint64_t)fdStat.st_size;

		memset(fileMeta.fileName, 0, sizeof(fileMeta.fileName) / sizeof(fileMeta.fileName[0]));
		strncpy(fileMeta.fileName, file, sizeof(fileMeta.fileName) / sizeof(fileMeta.fileName[0]));
		fileMeta.fileSize = fileSize;

		memcpy(fileMetaBuffer, &fileMeta, sizeof(FileMeta));

		MeshSendToAllPeers(mh, fileMetaBufferId, fileMetaBuffer, fileMetaBufferSize);

		printf("Sending %s of size: %lld\n", fileMeta.fileName, fileMeta.fileSize);
	} else {
		fd = open(file, O_RDWR | O_CREAT | O_TRUNC, 0644);
		if (fd < 0) {
			printf("Cannot open %s for writing\n", file);
			exit(1);
		}

		MeshReceiveFromLeader(mh, fileMetaBufferId, fileMetaBuffer, fileMetaBufferSize, 0);

		memcpy(&fileMeta, fileMetaBuffer, sizeof(FileMeta));

		printf("Receiving %s of size: %lld into %s\n", fileMeta.fileName, fileMeta.fileSize, file);
	}

	uint64_t transferOffset = 0;

	uint64_t startTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
	uint32_t curIdx    = 0;

	for (uint32_t i = 0; i < fileTransferBufferCount; i++) {
		bufferSem[i] = dispatch_semaphore_create(1);
	}
	while (transferOffset < fileMeta.fileSize) {
		uint64_t amt;

		dispatch_semaphore_wait(bufferSem[curIdx], DISPATCH_TIME_FOREVER);

		if (myNodeId == MESH_DEFAULT_LEADER_NODE_ID) {
			amt = (uint64_t)read(fd, fileTransferBufferPtrs[curIdx], fileTransferBufferSize);
			if ((ssize_t)amt <= 0) {
				break;
			}

			dispatch_group_async(group, copyWorkerQueue, ^{
			  MeshSendToAllPeers(mh, fileTransferBufferIdBase + curIdx, fileTransferBufferPtrs[curIdx], amt);
			  dispatch_semaphore_signal(bufferSem[curIdx]);
			});

		} else {
			if (transferOffset + fileTransferBufferSize > fileMeta.fileSize) {
				amt = fileMeta.fileSize - transferOffset;
			} else {
				amt = fileTransferBufferSize;
			}

			MeshReceiveFromLeader(mh, fileTransferBufferIdBase + curIdx, fileTransferBufferPtrs[curIdx], amt, 0);
			dispatch_group_async(group, copyWorkerQueue, ^{
			  // printf("writing to offset 0x%llx amt %lld curIdx %d\n", transferOffset, amt, curIdx);
			  pwrite(fd, fileTransferBufferPtrs[curIdx], amt, (off_t)transferOffset);
			  dispatch_semaphore_signal(bufferSem[curIdx]);
			});
		}

		transferOffset += amt;
		curIdx = (curIdx + 1) % fileTransferBufferCount;
	}

	dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

	uint64_t endTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
	if (myNodeId == MESH_DEFAULT_LEADER_NODE_ID) {
		printf("Took %f seconds to transfer %lld bytes.\nTotal Time: %f seconds.\n",
		       (double)(endTime - startTime) / (double)kNsPerSecond, fileMeta.fileSize,
		       (double)(endTime - startTime) / (double)kNsPerSecond);
	} else {
		printf("Done receiving file.\n");
	}

	for (uint32_t i = 0; i < fileTransferBufferCount; i++) {
		MeshReleaseBuffer(mh, fileTransferBufferIdBase + i, fileTransferBufferSize);
	}
	MeshReleaseBuffer(mh, fileMetaBufferId, fileMetaBufferSize);

	MeshReleaseClaim(mh);

	close(fd);

	return 0;
}
