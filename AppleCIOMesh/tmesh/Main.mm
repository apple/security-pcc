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
//
// tmesh - a test program for the mesh.  intended to exercise
// the driver in various ways similar to how it will be used in practice.
// the intent is not to explore every possible dark corner of the driver
// but rather to make sure that all the possible use cases we care about
// work reliably.
//
// tmesh intentionally does not do actual gpu work like llmsim or the
// real inferencing process.  this is to avoid Metal dependencies.
//
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

static os_log_t logHandle   = os_log_create("com.apple.tmesh", "signpost");
static auto badDataSignpost = os_signpost_id_generate(logHandle);

void
pause(const char * msg)
{
	printf("%s : press enter to continue", msg);
	fflush(stdout);
	char tmp[50];
	fgets(tmp, sizeof(tmp), stdin);
}

static void
usage(char * name)
{
	fprintf(stderr, "usage:\n");
	fprintf(stderr, "\t%s [-matrix N] [-mynodeid X] [-numnodes Y] [-bid BUFFER-ID]\n", name);
	fprintf(stderr, "\t matrix size, mynodeid and numnodes are all required.  buffer-id is optional.\n");
	fprintf(stderr,
	        "options: set environment variable MESH_CRYPTO=1 to enable encryption\n"
	        "         env var MESH_VERBOSE=1 for extremely verbose logging.\n");
}

uint64_t
getArg(const char * arg)
{
	char * ptr   = nullptr;
	uint64_t val = strtoul(arg, &ptr, 0);

	if (*ptr == 'k' || *ptr == 'K') {
		val *= 1024;
	} else if (*ptr == 'm' || *ptr == 'M') {
		val *= 1024 * 1024;
	} else if (*ptr == 'g' || *ptr == 'G') {
		val *= 1024 * 1024 * 1024;
	}

	return val;
}

#define kBytesPerGiga (1000000000)
#define kNsPerSecond (1000000000.0)
#define kUsPerSecond (1000000.0)

static void
log_stats(MeshHandle_t * mh, MeshBufferState_t * mbs)
{
	uint64_t curTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
	if (mbs->curIteration == 0) {
		mh->stats.lastLog = curTime;
	}
	if (mh->verbose_level > 0 && mbs->curIteration > 0 && (double)(curTime - mh->stats.lastLog) >= kNsPerSecond * 4) {
		mh->stats.lastLog = curTime;

		double averageSyncTimeUsec = ((double)mh->stats.syncTotalTime / (double)mh->stats.syncCounter) / 1000.0;

		printf("avg sync time: %8.2f usec; minSync %lld usec on iter %lld; maxSync: %lld usec\n", averageSyncTimeUsec,
		       mh->stats.syncMinTime / 1000, mh->stats.syncMinIter, mh->stats.syncMaxTime / 1000);
		if (mh->cryptoKeyArray.key_count > 0) {
			printf("encrypt avg: %f usec (%lld) decrypt avg: %f usec (%lld); crypto Wait Total: %lld usecs per wait\n",
			       (float)mh->stats.encrypt_total_time / (float)mh->stats.num_encrypt / 1000.0, mh->stats.num_encrypt,
			       (float)mh->stats.decrypt_total_time / (float)mh->stats.num_decrypt / 1000.0, mh->stats.num_decrypt,
			       (mh->stats.cryptoWaitTotal / mh->stats.cryptoWaitCount) / 1000);
		}

		mh->stats.syncCounter   = 0;
		mh->stats.syncMinTime   = 999999999999;
		mh->stats.syncMaxTime   = 0;
		mh->stats.syncMinIter   = -1;
		mh->stats.syncTotalTime = 0;

		mh->stats.averageIncomingCounter = 0;
		mh->stats.averageOutgoingCounter = 0;
		fprintf(stdout, "Average Outgoing Speed: %f Gbps\n", mh->stats.averageOutgoingSpeed);

		printf("Sync Time Histogram:\n");
		uint64_t base = 0;
		for (int i = 0; i < MESH_SYNC_HISTOGRAM_COUNT; i++) {
			if (mh->stats.syncTimeHistogram[i] != 0) {
				if (i < MESH_SYNC_HISTOGRAM_COUNT - 1) {
					printf("    %6lld - %6lld usec: %lld\n", base, mh->stats.syncTimeHistogramBins[i],
					       mh->stats.syncTimeHistogram[i]);
				} else {
					printf("           > %6lld usec: %lld\n", base, mh->stats.syncTimeHistogram[i]);
				}
			}
			base = mh->stats.syncTimeHistogramBins[i] + 1;
		}
	}
}

MeshHandle_t * global_mh       = NULL; // only for the signal handler
MeshBufferState_t * global_mbs = NULL;

void
tmesh_SigIntHandler(int)
{
	if (global_mh && global_mbs) {
		printf(
		    "SIGINT!!!! curIter %lld curBufIdx %d rcvdCount %d sentSize %lld bufferSent %s readers can run %d "
		    "nthr %d\n",
		    global_mbs->curIteration, global_mbs->curBufferIdx, global_mbs->bufferInfo[global_mbs->curBufferIdx].chunkReceiveCount,
		    global_mbs->bufferInfo[global_mbs->curBufferIdx].sentSize,
		    global_mbs->bufferInfo[global_mbs->curBufferIdx].blockSent ? "YES" : "NO", global_mh->reader_active,
		    global_mh->num_threads);

		MeshStopReaders(global_mh);

#if 0
		printf("Sync Time Histogram:\n");
		uint64_t base=0;
		for(int i=0; i < MESH_SYNC_HISTOGRAM_COUNT; i++) {
			printf("    %6lld - %6lld usec: %lld\n", base, global_mh->stats.syncTimeHistogramBins[i],  global_mh->stats.syncTimeHistogram[i]);
			base = global_mh->stats.syncTimeHistogramBins[i] + 1;
		}
#endif
		//	dump_crypto_state(global_mh);
	}
	exit(1);
}

#define FLOAT_T float

void
generateFixedData(FLOAT_T * dataPtr, unsigned int bufferSize)
{
	for (unsigned long index = 0; index < bufferSize / sizeof(FLOAT_T); index++) {
		dataPtr[index] = (FLOAT_T)1.0;
	}
}

#define NUM_LAYERS (16)

FLOAT_T * matC_array[NUM_LAYERS];

// just an arbitrary value that's distinct from the bufferId's used for the layers
const uint32_t sendToAllBufferId = 0x1000;
// for now let's just create a 4 megabyte scatter buffer
uint64_t sendToAllBufSize = 4 * 1024 * 1024;
// the actual scatter buffer pointer
void * sendToAllBuf = NULL;

// just an arbitrary value that's distinct from the bufferId's used for the layers
// const uint32_t scatterToAllBufferId = 0x2000;
// for now let's just create a 4 megabyte scatter buffer
uint64_t scatterToAllBufSize = 4 * 1024 * 1024;
// the actual scatter buffer pointer
void * scatterToAllBuf = NULL;

//
// Variables to control tmesh behavior
//
uint32_t usleep_delay = 150;
uint32_t max_iters    = 0;

void
tmesh_worker(MeshHandle_t * mh, MeshBufferState * mbs)
{
	uint32_t bufferIdx = mbs->curBufferIdx;

	// printf("Starting reader threads! (max iters: %d)\n", max_iters);
	uint32_t total_iters    = 0;
	const uint32_t base_val = 0x534b4447; // 'SKDG'
	bool keep_going         = true;

	while (keep_going && (max_iters == 0 || total_iters < max_iters)) {
		// printf("Starting global iteration %d, repeat %d max_iters %d\n", total_iters + 1, repeat, max_iters);
		uint32_t * my_data = (uint32_t *)matC_array[bufferIdx];
		my_data            = &my_data[(mh->myNodeId * mbs->userBlockSize) / sizeof(FLOAT_T)];
		// fill in the expected data so that verification works
		for (uint32_t i = 0; i < mbs->userBlockSize / sizeof(FLOAT_T); i++) {
			// make the pattern change based on where in the buffer we are
			my_data[i] = base_val ^ total_iters ^ i;
		}
		// pretend the gpu took some time do something
		usleep(usleep_delay);

		// now send our results to everyone else and wait for
		// the results from all our peers

		//
		// printf("Broadcast + gather.\n");
		int ret;
		ret = MeshBroadcastAndGather(mh, mbs);
		if (ret != 0) {
			printf("BroadcastAndGather failed (%d) - bailing out.\n", ret);
			keep_going = false;
			exit(10);
		}

		{
			//
			// Verify the result.  We check all matrices from all
			// nodes.  The expected value is base_val ^ total_iters
			// so that we have an interesting data pattern that
			// changes each iteration.
			//
			FLOAT_T * matC = matC_array[bufferIdx];
			for (uint32_t k = 0; k < mh->localNodeCount; k++) {
				uint32_t * mat_data = (uint32_t *)matC;
				mat_data            = &mat_data[k * (mbs->userBlockSize / sizeof(FLOAT_T))];

				uint32_t first_bad_offset  = (uint32_t)~0;
				uint32_t first_good_offset = (uint32_t)~0;
				bool header_printed        = false;
				bool had_errs              = false;

				for (uint32_t i = 0; i < mbs->userBlockSize / sizeof(FLOAT_T); i++) {
					if (mat_data[i] != (base_val ^ total_iters ^ i)) {
						if (first_bad_offset == (uint32_t)~0) {
							first_bad_offset = i;
						}
						if (!header_printed) {
							printf("Matrix Multiply result is incorrect on iteration %d, layer %d, from node=%d\n", total_iters,
							       bufferIdx, k);
							header_printed = true;
						}
						// printf("err: i %d j %d : %f\n", i, j, mat_data[i*M + j]);
						had_errs = true;
					} else if (first_good_offset == (uint32_t)~0) {
						first_good_offset = i;
					}
				}
				if (first_bad_offset != (uint32_t)~0) {
					os_signpost_event_emit(logHandle, badDataSignpost, "MATMUL", "baddata %lu", first_bad_offset * sizeof(FLOAT_T));
					printf("data at bad offset %zd: 0x%x 0x%x 0x%x ## ", first_bad_offset * sizeof(FLOAT_T),
					       *(uint32_t *)&mat_data[first_bad_offset + 0], *(uint32_t *)&mat_data[first_bad_offset + 1],
					       *(uint32_t *)&mat_data[first_bad_offset + 2]);
					if (first_good_offset != (uint32_t)~0) {
						printf("data at good offset %zd: 0x%x 0x%x 0x%x\n", first_good_offset * sizeof(FLOAT_T),
						       *(uint32_t *)&mat_data[first_good_offset + 0], *(uint32_t *)&mat_data[first_good_offset + 1],
						       *(uint32_t *)&mat_data[first_good_offset + 2]);
					}
				}
			}

			// clear the matrix so that the next time around the data
			// has to be transferred or the verification will fail.
			memset(matC, (int)(0xe0 | mh->myNodeId), mbs->userBlockSize * mh->localNodeCount);
		}

		log_stats(mh, mbs); // periodically log stats on sync performance

		// done this iteration/layer, move on to the next one
		bufferIdx = (bufferIdx + 1) % mbs->numBuffers;
		total_iters++;
	}

	printf("Tmesh worker all done after %d iterations.\n", total_iters);
}

static void *
allocateBuffer(uint64_t bufferSize)
{
	uint8_t * buffer;
	if (posix_memalign((void **)&buffer, 1 << 14, bufferSize) != 0) {
		fprintf(stderr, "failed to allocate memaligned buffer\n");
		return NULL;
	};

	// make sure all the memory is present so that the cost of faulting
	// in the pages isn't paid for by other code.
	memset(buffer, 0xa5, bufferSize);

	return buffer;
}

#define DEFAULT_TMESH_BUFFER_ID 0x10000000 // just a value

int
main(int argc, char ** argv)
{
	uint32_t bufferIdArg  = 0;
	uint32_t myNodeId     = (uint32_t)~0;
	uint32_t leaderNodeId = MESH_DEFAULT_LEADER_NODE_ID;
	uint32_t baseNodeId   = 0;
	uint32_t nodeCount    = 0;
	uint64_t blockSize;
	uint64_t bufferSize;
	uint64_t chunkSize;
	uint32_t numBuffers   = NUM_LAYERS;
	uint32_t maxBlockSize = 512 * 1024;
	uint32_t minChunkSize = 8192 * 2;
	void ** bufferPtrs;

	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "-maxblock") == 0 && i + 1 < argc) {
			maxBlockSize = (uint32_t)getArg(argv[i + 1]);
			i++;
		} else if (strcmp(argv[i], "-leaderid") == 0 && i + 1 < argc) {
			leaderNodeId = (uint32_t)getArg(argv[i + 1]);
			i++;
		} else if (strcmp(argv[i], "-basenodeid") == 0 && i + 1 < argc) {
			// eventually we'll support node-id's that don't start at zero
			baseNodeId = (uint32_t)getArg(argv[i + 1]);
			i++;
		} else if (strcmp(argv[i], "-delay") == 0 && i + 1 < argc) {
			usleep_delay = (uint32_t)getArg(argv[i + 1]);
			i++;
			printf("Delay set to %d\n", usleep_delay);
		} else if (strcmp(argv[i], "-minchunk") == 0 && i + 1 < argc) {
			minChunkSize = (uint32_t)getArg(argv[i + 1]);
			i++;
			printf("Minimum chunk size set to %d\n", minChunkSize);
		} else if (strcmp(argv[i], "-bid") == 0 && i + 1 < argc) {
			bufferIdArg = (uint32_t)getArg(argv[i + 1]);
			i++;
		} else if (strcmp(argv[i], "-maxiter") == 0 && i + 1 < argc) {
			max_iters = (uint32_t)getArg(argv[i + 1]);
			printf("Will run for %d iterations\n", max_iters);
			i++;
		} else {
			printf("Unknown argument: %s\n", argv[i]);
		}
	}

	if (!MeshGetInfo(&myNodeId, &nodeCount)) {
		printf("Could not get basic info about my node-id or the number of nodes.  Fail.\n");
		exit(1);
	}

	if (maxBlockSize == 0 || myNodeId == (uint32_t)~0 || nodeCount == 0) {
		usage(argv[0]);
		exit(1);
	}
	if (bufferIdArg == 0) {
		// can't use zero as a bufferId and it wasn't specified on the
		// command line so use a default.
		bufferIdArg = DEFAULT_TMESH_BUFFER_ID;
	}

	char * delay_str = getenv("MESH_DELAY");
	if (delay_str) {
		usleep_delay = (uint32_t)strtol(delay_str, NULL, 0);
		printf("Using usleep delay of: %d\n", usleep_delay);
	}

	// The matrix is a square matrix to make verification easier
	// Also note that the output of each node's computation gets
	// concatenated in the output buffer which is numnodes times
	// the size of the matrix.

	blockSize  = (maxBlockSize) * sizeof(FLOAT_T);
	bufferSize = (nodeCount * blockSize);
	/*    if ((blockSize % 8) == 0 && (blockSize / 8) > minChunkSize) {
	 chunkSize = blockSize / 8;
	 } else */
	if ((blockSize % 4) == 0 && (blockSize / 4) >= minChunkSize && ((blockSize / 4) % 4096) == 0) {
		chunkSize = blockSize / 4;
	} else if ((blockSize % 3) == 0 && (blockSize / 3) >= minChunkSize && ((blockSize / 3) % 4096) == 0) {
		chunkSize = blockSize / 3;
	} else if ((blockSize % 2) == 0 && (blockSize / 2) >= minChunkSize && ((blockSize / 2) % 4096) == 0) {
		chunkSize = blockSize / 2;
	} else {
		chunkSize = blockSize;
	}

	if ((blockSize % 4096) != 0) {
		printf(
		    "Block size %lld is not going to work out (bufferSize %lld chunkSize %lld which are not a multiple "
		    "of 4k)\n",
		    blockSize, bufferSize, chunkSize);
		exit(1);
	}

	printf("bufferSize %lld blockSize %lld chunkSize %lld\n", bufferSize, blockSize, chunkSize);

	uint32_t me, totalNodes;
	if (MeshGetInfo(&me, &totalNodes)) {
		printf("*** I am %d and there are %d nodes\n", me, totalNodes);
	} else {
		printf("Failed to get info about the mesh.\n");
	}

	static const char * key = "123456789abcdef0123456789abcdef0";
	printf("Setting crypto key\n");
	MeshSetCryptoKey(key, strlen(key));

	//
	// Here is where we create a MeshHandle, setup the buffers and
	// get read to start doing work.
	//
	MeshHandle_t * mh;

	printf("Creating mesh handle\n");
	mh = MeshCreateHandle(leaderNodeId);
	if (!mh) {
		printf("Could not setup the mesh.\n");
		exit(2);
	}

	global_mh = mh; // only for the sigint handler
	signal(SIGINT, tmesh_SigIntHandler);

	//
	// These are the app buffers.  In a real app these would be the
	// K and Q vectors.  But really they can be any chunk of memory
	// that has a page aligned start address and is a multiple of
	// the chunkSize.
	//
	printf("Alloc buffer ptrs\n");
	bufferPtrs = (void **)calloc(numBuffers, sizeof(void *));
	if (bufferPtrs == NULL) {
		printf("No memory for buffer pointers?!\n");
		exit(1);
	}

	printf("Init buffers\n");
	for (uint32_t i = 0; i < numBuffers; i++) {
		FLOAT_T * matC;

		// matrix C is sized to accomodate the results from each node
		matC_array[i] = matC = (FLOAT_T *)malloc(blockSize * nodeCount);

		bufferPtrs[i] = (void *)matC;
		int ret       = mlock(bufferPtrs[i], blockSize * nodeCount);
		if (ret != 0) {
			printf("mlock() of bufferPtrs[%d] %p / %p / %llu failed ret=%d\n", i, bufferPtrs[i], matC, blockSize * nodeCount, ret);
		}

		// clear the matrix so that we know if data syncs before it was supposed to
		memset(matC, (int)(0xa0 | mh->myNodeId), blockSize * nodeCount);
	}

	// Send-To-All buffer allocation
	printf("Alloc send-to-all buffer\n");
	if ((sendToAllBufSize % nodeCount) != 0) {
		printf("sendToAllBufSize %lld isn't evenly divisble by the nodeCount %d. adjusting it.\n", sendToAllBufSize, nodeCount);
		sendToAllBufSize = (1024 * 1024) * nodeCount;
	}
	sendToAllBuf = allocateBuffer(sendToAllBufSize);
	if (sendToAllBuf == NULL) {
		printf("no memory for the send-to-all buffer.\n");
		exit(3);
	}
	if (leaderNodeId == myNodeId) {
		uint32_t n = 0;
		for (uint64_t i = 0; i < sendToAllBufSize; i += sendToAllBufSize / nodeCount, n++) {
			// make sure each node gets something different
			memset((char *)sendToAllBuf + i, (int)(0x80 | n), sendToAllBufSize / nodeCount);
		}
	} else {
		// fill it with garbage
		memset((char *)sendToAllBuf, 0xe9, sendToAllBufSize);
	}

	// Scatter-To-All buffer Allocation
	printf("Alloc scatter-to-all buffer\n");
	if ((scatterToAllBufSize % nodeCount) != 0) {
		printf("scatterToAllBufSize %lld isn't evenly divisble by the nodeCount %d. adjusting it.\n", scatterToAllBufSize,
		       nodeCount);
		scatterToAllBufSize = (1024 * 1024) * nodeCount;
	}
	scatterToAllBuf = allocateBuffer(scatterToAllBufSize);
	if (scatterToAllBuf == NULL) {
		printf("no memory for the scatter buffer.\n");
		exit(3);
	}

	if (leaderNodeId == myNodeId) {
		uint32_t n = 0;
		for (uint64_t i = 0; i < scatterToAllBufSize; i += scatterToAllBufSize / nodeCount, n++) {
			// make sure each node gets something different
			memset((char *)scatterToAllBuf + i, (int)(0xb0 | n), scatterToAllBufSize / nodeCount);
		}
	} else {
		// fill it with garbage
		memset((char *)scatterToAllBuf, 0x9d, scatterToAllBufSize);
	}

	if (auto res = MeshSetupSendToAllBuffer(mh, sendToAllBufferId, sendToAllBuf, sendToAllBufSize); 0 != res) {
		printf("MeshSetupSendToAllBuffer failed\n");
		return res;
	}
	printf("MeshSetupSendToAllBuffer finished\n");
	if (mh->myNodeId == mh->leaderNodeId) {
		printf("I am the leader!  Sending the send-to-all buffer to everyone\n");
		// XXXdbg - this makes sure that all the followers are waiting to receive
		// data; otherwise if the leader broadcasts before they're ready, they
		// will never receive the data
		usleep(500000);
		MeshSendToAllPeers(mh, sendToAllBufferId, sendToAllBuf, sendToAllBufSize);
	} else {
		// printf("I am a worker-bee buzz buzz: receiving the send-to-all buffer from the leader\n");
		MeshReceiveFromLeader(mh, sendToAllBufferId, sendToAllBuf, sendToAllBufSize, 0);
	}
	printf("releasing send-to-all buffer.\n");
	MeshReleaseBuffer(mh, sendToAllBufferId, sendToAllBufSize);

	printf("recreating the send-to-all buffer id\n");
	// now recreate it to make sure that this works
	int err;
	if ((err = MeshSetupSendToAllBuffer(mh, sendToAllBufferId, sendToAllBuf, sendToAllBufSize)) != 0) {
		printf("failed to recreate the send-to-all buffer err %d.\n", err);
		exit(1);
	}
	MeshReleaseBuffer(mh, sendToAllBufferId, sendToAllBufSize);

	printf("Send-to-all & Receive done.\n");
	{
		unsigned char * ptr = (unsigned char *)sendToAllBuf;
		// check that we got what we expect
		for (uint32_t i = 0; i < mh->localNodeCount; i++) {
			if (ptr[i * (sendToAllBufSize / mh->localNodeCount)] != (0x80 | i)) {
				printf("Error: on peer %d send-to-all buf for node %d is 0x%x not 0x%x\n", mh->myNodeId, i,
				       ptr[i * (sendToAllBufSize / mh->localNodeCount)] & 0xff, 0x80 | i);
				exit(5);
			}
		}
	}

	// MeshReleaseBuffers(mh, sendToAllBufferId, 1, sendToAllBufSize);

#if 0
	uint64_t scatterToAllBlockSize = scatterToAllBufSize / mh->nodeCount;

	MeshSetupScatterToAllBuffer(mh, scatterToAllBufferId, scatterToAllBuf, scatterToAllBufSize);

	if (mh->myNodeId == mh->leaderNodeId) {
		printf("I am the leader!  Sending scatter buffer to eeach peer individually\n");
		// XXXdbg - this makes sure that all the followers are waiting to receive
		// data; otherwise if the leader broadcasts before they're ready, they
		// will never receive the data
		usleep(500000);
		MeshScatterToAll(mh, scatterToAllBufferId, scatterToAllBuf, scatterToAllBufSize);
	} else {
		// printf("I am a worker-bee buzz buzz: receiving just my data from the leader\n");
		uint64_t myOffset = (mh->myNodeId * scatterToAllBlockSize);

		MeshReceiveFromLeader(mh, scatterToAllBufferId, scatterToAllBuf, scatterToAllBlockSize, myOffset);
		for (uint64_t offset = 0; offset < scatterToAllBufSize; offset += scatterToAllBlockSize) {
			unsigned char * ptr = (unsigned char *)scatterToAllBuf;
			printf("node %lld at offset 0x%llx == 0x%x\n", offset / scatterToAllBlockSize, offset, (uint32_t)ptr[offset]);
		}
	}
	printf("Scatter / Receive all done.\n");
	{
		unsigned char * ptr = (unsigned char *)scatterToAllBuf;
		uint64_t myOffset   = (mh->myNodeId * scatterToAllBlockSize);
		if (ptr[myOffset] != (0xb0 | mh->myNodeId)) {
			printf("Error: scatter buf for node %d is 0x%x not 0x%x\n", mh->myNodeId, ptr[myOffset] & 0xff, 0xb0 | mh->myNodeId);
			exit(5);
		}
	}
#endif
	// MeshReleaseBuffers(mh, scatterToAllBufferId, 1, scatterToAllBufSize);

	printf("Starting the main test....\n");

	uint32_t msize;
	for (msize = 68 * 1024; msize <= maxBlockSize; msize += 1024) {
		blockSize  = msize;
		bufferSize = (nodeCount * blockSize);

		printf("*** Test with blockSize %lld bufferSize %lld\n", blockSize, bufferSize);

		// printf("Setting up the main sync buffers\n");
		MeshBufferState_t * mbs;
		if (MeshSetupBuffers(mh, bufferIdArg + blockSize, bufferSize, blockSize, 0, bufferPtrs, numBuffers, &mbs) != 0) {
			printf("Bah Humbug!  Failed to setup the buffers.\n");
			exit(99);
		}
		global_mbs = mbs;

		MeshStartReaders(mh);

		for (uint32_t iters = 32; iters < 64; iters++) {
			max_iters = iters;

			MeshAssignBuffersToReaders(mh, mbs, max_iters);

			tmesh_worker(mh, mbs);

			usleep(100000);
		}

		// XXXdbg - calling this can trigger a panic if the readers aren't done
		MeshReleaseBuffers(mh, mbs);
		printf("Done releasing buffers\n");

		usleep(1000000);
	}

	if (!MeshStopReaders(mh)) {
		printf("Failed to stop readers!\n");
	}

	return 0;
}
