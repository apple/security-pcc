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

#include <AssertMacros.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <atomic>
#include <ctype.h>
#include <err.h>
#include <mach/mach_time.h>
#include <math.h>
#include <os/log.h>
#include <os/signpost_private.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <sysexits.h>
#include <unistd.h>
#include <vector>

#include "json.h"

extern "C" {
#include <corecrypto/ccmode.h>
}

#include <IOKit/IOKitLib.h>
#include <IOReport.h>

#import <AppleCIOMeshConfigSupport/AppleCIOMeshConfigSupport.h>
#import <AppleCIOMeshSupport/AppleCIOMeshAPI.h>
#import <AppleCIOMeshSupport/AppleCIOMeshAPIPrivate.h>
#import <AppleCIOMeshSupport/AppleCIOMeshSupport.h>

static os_log_t logHandle   = os_log_create("com.apple.llmsim", "signpost");
static auto badDataSignpost = os_signpost_id_generate(logHandle);
static auto statsSignpost   = os_signpost_id_generate(logHandle);
static auto verifySignpost  = os_signpost_id_generate(logHandle);

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
	fprintf(stderr, "\t%s [-bsize N] [-delay usec] [-minchunk X] [-maxiter N] [-testloop L] [-noverify] [-exitonerr]\n", name);
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
log_stats(MeshHandle_t * mh, MeshBufferState_t * mbs, bool forced)
{
	uint64_t curTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
	if (mh->verbose_level >= LogStats && mbs->curIteration > 0 &&
	    ((double)(curTime - mh->stats.lastLog) >= kNsPerSecond * 4 || forced)) {
		mh->stats.lastLog = curTime;

		double averageSyncTimeUsec = ((double)mh->stats.syncTotalTime / (double)mh->stats.syncCounter) / 1000.0;

		printf("Transfer Time: %lld usec; drifted sync time: %8.2f usec; maxSync: %lld usec.\n", mh->stats.syncMinTime / 1000,
		       averageSyncTimeUsec, mh->stats.syncMaxTime / 1000);
		if (mh->cryptoKeyArray.key_count > 0) {
			printf("encrypt avg: %f usec (%lld) decrypt avg: %f usec (%lld); crypto Wait Total: %lld usecs per wait\n",
			       (float)mh->stats.encrypt_total_time / (float)mh->stats.num_encrypt / 1000.0, mh->stats.num_encrypt,
			       (float)mh->stats.decrypt_total_time / (float)mh->stats.num_decrypt / 1000.0, mh->stats.num_decrypt,
			       (mh->stats.cryptoWaitTotal / mh->stats.cryptoWaitCount) / 1000);
		}
		printf("last node sync count: ");
		for (size_t i = 0; i < sizeof(mh->stats.lastNodeToSyncCount) / sizeof(mh->stats.lastNodeToSyncCount[0]); i++) {
			printf(" %lld", mh->stats.lastNodeToSyncCount[i]);
		}
		printf("\n");

		fprintf(stdout, "Average Outgoing Speed: %f Gbps. Maximum Outgoing Speed: %f Gbps\n", mh->stats.averageOutgoingSpeed,
		        mh->stats.outgoingSize / ((double)mh->stats.syncMinTime / kNsPerSecond));

		mh->stats.syncCounter   = 0;
		mh->stats.syncMinTime   = 999999999999;
		mh->stats.syncMaxTime   = 0;
		mh->stats.syncMinIter   = -1;
		mh->stats.syncTotalTime = 0;

		mh->stats.averageIncomingCounter = 0;
		mh->stats.averageOutgoingCounter = 0;

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
llmsimSigIntHandler(int)
{
	if (global_mh && global_mbs) {
		printf(
		    "SIGINT!!!! curIter %lld curBufIdx %d rcvdCount %d (0x%x) sentSize %lld bufferSent %s readers can "
		    "run %d nthr %d\n",
		    global_mbs->curIteration, global_mbs->curBufferIdx, global_mbs->bufferInfo[global_mbs->curBufferIdx].chunkReceiveCount,
		    global_mbs->bufferInfo[global_mbs->curBufferIdx].blockReceiveMask,
		    global_mbs->bufferInfo[global_mbs->curBufferIdx].sentSize,
		    global_mbs->bufferInfo[global_mbs->curBufferIdx].blockSent ? "YES" : "NO", global_mh->reader_active,
		    global_mh->num_threads);

		MeshDestroyHandle(global_mh);
	}
	exit(1);
}

#define FLOAT_T uint32_t
#define DEFAULT_BLOCK_SIZE 16384

void
generateFixedData(void * buffer, unsigned int bufferSize)
{
	FLOAT_T * dataPtr = (FLOAT_T *)buffer;
	for (unsigned long index = 0; index < bufferSize / sizeof(FLOAT_T); index++) {
		dataPtr[index] = (FLOAT_T)1.0;
	}
}

#define NUM_LAYERS (4)
void * backingDataBuffers[NUM_LAYERS];

// just an arbitrary value that's distinct from the bufferId's used for the layers
const uint64_t sendToAllBufferMask = 0x1000000000000000;
// for now let's just create a 128 kilobyte scatter buffer
uint64_t sendToAllBufSize = 128 * 1024;
// the actual scatter buffer pointer
void * sendToAllBuf = NULL;

// just an arbitrary value that's distinct from the bufferId's used for the layers
// const uint64_t scatterToAllBufferMask = 0x2000000000000000;
// for now let's just create a 4 megabyte scatter buffer
uint64_t scatterToAllBufSize = 4 * 1024 * 1024;
// the actual scatter buffer pointer
void * scatterToAllBuf = NULL;

// Broadcast & Gather Buffers
// TODO: we can put this in a struct instead of a 2d-array of pointers
void ** cioMeshBufferPtrs;

// A global buffer id
uint64_t globalBufferId = 1;

uint32_t myNodeId     = (uint32_t)~0;
uint32_t leaderNodeId = MESH_DEFAULT_LEADER_NODE_ID;
uint32_t nodeCount    = 0;
uint64_t blockSize    = 0;
uint64_t bufferSize;
uint64_t chunkSize;
uint32_t numBuffers     = NUM_LAYERS;
uint32_t minChunkSize   = 8192;
uint32_t bufferSetCount = 1;

uint64_t nodeMask = (uint32_t)(-1);
bool copyNetRx    = false;

atomic_bool rtThreadReady = false;

//
// Variables to control llm_worker's behavior
//
uint32_t usleep_delay       = 150;
uint64_t max_iters          = 0;
uint32_t num_syncs_per_iter = 96;
bool do_gpu_work            = true;
bool do_verification        = true;
bool exit_on_errs           = false;
bool do_send_to_all         = true;
bool log_latencies          = false;
char * latency_log_file     = NULL;
uint64_t err_count          = 0;
uint64_t bytes_sent         = 0;
uint64_t bytes_received     = 0;
uint32_t test_loop_count    = 1;
char * crypto_key           = NULL;
int8_t overridePartition    = -1;

static uint8_t
getNodeCountFromMask(uint64_t mask)
{
	return (uint8_t)__builtin_popcountll(mask);
}

static bool
isNodeParticipating(uint32_t nodeRank, uint64_t mask)
{
	uint64_t value = 1ULL << nodeRank;
	return (mask & value) != 0;
}

void
write_data_to_file(std::vector<uint64_t> sync_numbers)
{
	const char * path = latency_log_file;
	FILE * file       = fopen(path, "w");
	if (!file) {
		printf("Failed to open file '%s'\n", path);
	}

	fprintf(file, "%lu sync durations in nanoseconds:\n", sync_numbers.size());

	for (auto i : sync_numbers) {
		fprintf(file, "%llu,", i);
	}
	fclose(file);
	printf("Sync numbers written to file '%s'\n", path);
}

int
llm_worker(MeshHandle_t * mh, uint64_t sendAllBufferId, uint64_t scatterAllBufferId, MeshBufferSet_t * syncBufferSets)
{
	printf("llm worker is alive.\n");

	const uint32_t leaderNodeId          = __builtin_ctzll(syncBufferSets->nodeMask);
	const uint8_t participatingNodeCount = getNodeCountFromMask(syncBufferSets->nodeMask);

	if (sendAllBufferId != 0) {
		if (mh->myNodeId == leaderNodeId) {
			printf("I am the leader!  Sending the send-to-all buffer to everyone\n");
			sleep(1);
			MeshSendToAllPeers(mh, sendAllBufferId, sendToAllBuf, sendToAllBufSize);
		} else {
			// printf("I am a worker-bee buzz buzz: receiving the send-to-all buffer from the leader\n");
			MeshReceiveFromLeaderEx(mh, leaderNodeId, sendAllBufferId, sendToAllBuf, sendToAllBufSize, 0);
		}

		printf("Send-to-all & Receive done.\n");

		unsigned char * ptr = (unsigned char *)sendToAllBuf;
		// check that we got what we expect
		for (uint32_t i = 0; i < participatingNodeCount; i++) {
			if (ptr[i * (sendToAllBufSize / participatingNodeCount)] != (0x80 | i)) {
				printf("Error: on peer %d send-to-all buf for node %d is 0x%x not 0x%x\n", mh->myNodeId, i,
				       ptr[i * (sendToAllBufSize / participatingNodeCount)] & 0xff, 0x80 | i);
			}
		}
	}

	if (scatterAllBufferId != 0) {
		uint64_t scatterToAllBlockSize = scatterToAllBufSize / mh->localNodeCount;

		if (mh->myNodeId == mh->leaderNodeId) {
			printf("I am the leader!  Sending scatter buffer to eeach peer individually\n");
			MeshScatterToAll(mh, scatterAllBufferId, scatterToAllBuf, scatterToAllBufSize);
		} else {
			// printf("I am a worker-bee buzz buzz: receiving just my data from the leader\n");
			uint64_t myOffset = (mh->myNodeId * scatterToAllBlockSize);
			MeshReceiveFromLeaderEx(mh, leaderNodeId, scatterAllBufferId, scatterToAllBuf, scatterToAllBlockSize, myOffset);
		}

		printf("Scatter / Receive all done.\n");

		unsigned char * ptr = (unsigned char *)scatterToAllBuf;
		for (uint32_t i = 0; i < mh->localNodeCount; i++) {
			if (ptr[i * (scatterToAllBufSize / mh->localNodeCount)] != (0xf0 | i)) {
				printf("Error: scatter buf for node %d is 0x%x not 0x%x\n", i,
				       ptr[i * (scatterToAllBufSize / mh->localNodeCount)] & 0xff, 0xf0 | i);
			}
		}
	}

	//
	// BEGIN CODE THAT CAN ACTUALLY SEND/RECEIVE DATA on the broadcast & gather buffer
	//
	uint64_t runningIterCount = 0;
	bool keep_going           = true;

	std::vector<uint64_t> sync_durations;
	sync_durations.reserve(max_iters * num_syncs_per_iter);

	while (keep_going && (max_iters == 0 || (runningIterCount < max_iters))) {
		// we will assign buffers every loop around the buffer, similar to what
		// MetalLM does.
		uint64_t numSyncs;
		if (max_iters == 0 || (max_iters - runningIterCount) > num_syncs_per_iter) {
			numSyncs = num_syncs_per_iter;
		} else {
			numSyncs = max_iters - runningIterCount;
			printf("Last lap - num_iters = %lld\n", numSyncs);
		}

		MeshExecPlan * execPlan = (MeshExecPlan *)malloc(bufferSetCount * sizeof(MeshExecPlan));
		// Set the max reads for this iteration around the loop
		for (auto bsCtr = 0; bsCtr < bufferSetCount; bsCtr++) {
			execPlan[bsCtr].maxReads = numSyncs;
			execPlan[bsCtr].mbs      = syncBufferSets[bsCtr].mbs;
		}

		uint64_t start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);

		if (MeshAssignBuffersToReadersBulk(mh, execPlan, (uint16_t)bufferSetCount) != 0) {
			printf("MeshSetPlan failed! (numSyncs: %lld)\n", numSyncs);
			err_count++;
			break;
		}

		for (auto bsCtr = 0; bsCtr < bufferSetCount; bsCtr++) {
			MeshBufferState_t * mbs = syncBufferSets[bsCtr].mbs;
			global_mbs              = mbs;

			uint32_t syncIterator                = 0;
			int buffer_idx_offset                = (runningIterCount % NUM_LAYERS);
			const uint8_t participatingNodeCount = getNodeCountFromMask(mbs->nodeMask);
			const auto myNodeOffset              = MeshGetBufferOffsetForNode(mh, mbs, mh->myNodeId);
			while (keep_going && syncIterator < numSyncs) {
				if (do_verification) {
					if (mh->verbose_level >= LogSignposts) {
						os_signpost_event_emit(logHandle, verifySignpost, "VerifyInitStart", "data len %lld",
						                       mbs->userBlockSize / sizeof(FLOAT_T));
					}
					FLOAT_T * my_data = (FLOAT_T *)backingDataBuffers[(buffer_idx_offset + syncIterator) % NUM_LAYERS];
					my_data           = &my_data[(myNodeOffset * mbs->userBlockSize) / sizeof(FLOAT_T)];
					// fill in the expected data so that verification works
					for (uint32_t i = 0; i < mbs->userBlockSize / sizeof(FLOAT_T); i++) {
						// make the pattern a little bit more interesting than it was before
						my_data[i] = (FLOAT_T)i | (myNodeOffset << 16) | (0xeeull << 24);
					}

					if (mh->verbose_level >= LogSignposts) {
						os_signpost_event_emit(logHandle, verifySignpost, "VerifyInitEnd", "data len %lld",
						                       mbs->userBlockSize / sizeof(FLOAT_T));
					}
				} // do_verification

				if (usleep_delay) {
					if (start == 0) {
						start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
					}

					while ((clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) < (usleep_delay * 1000)) {}

					start = 0;
				} // usleep_delay

				// now send our results to everyone else and wait for
				// the results from all our peers
				const auto start_timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
				int ret;
				ret = MeshBroadcastAndGather(mh, mbs);
				if (ret != 0) {
					printf("BroadcastAndGather failed (%d) - bailing out on iteration %lld for bufferSet %d.\n", ret,
					       runningIterCount, bsCtr);
					keep_going = false;
					err_count++;
					break;
				}
				const auto delta = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start_timestamp;
				if (log_latencies) {
					sync_durations.push_back(delta);
				}
				bytes_sent += mbs->userBlockSize * (mh->extendedNodeCount - 1);
				bytes_received += mbs->userBlockSize * (mh->extendedNodeCount - 1);

				if (do_verification) {
					//
					// Verify the result.  We check all buffer from all the
					// nodes to see that they contain the expected value.
					// The expected value could be a little bit more interesting.
					// Right now it's just the blockSize.
					//
					if (mh->verbose_level >= LogSignposts) {
						os_signpost_event_emit(logHandle, verifySignpost, "VerifyStart", "data len %lld",
						                       mbs->userBlockSize / sizeof(FLOAT_T));
					}
					for (uint32_t k = 0; k < participatingNodeCount; k++) {
						FLOAT_T * mat_data = (FLOAT_T *)backingDataBuffers[(buffer_idx_offset + syncIterator) % NUM_LAYERS];
						mat_data           = &mat_data[(k * mbs->userBlockSize) / sizeof(FLOAT_T)];

						uint32_t first_bad_offset  = (uint32_t)~0;
						uint32_t first_good_offset = (uint32_t)~0;
						bool header_printed        = false;
						bool had_errs              = false;

						for (uint32_t i = 0; i < mbs->userBlockSize / sizeof(FLOAT_T); i++) {
							auto temp = k;
							if (copyNetRx) {
								// In this test mode, the data has been copied from nodes in section 0 to all other
								// sections in the ensemble. So when verifying, we need to adjust k to be the
								// corresponding node from partition 0.
								temp = k % kMaxCIOMeshNodes;
							}
							if (mat_data[i] != (i | (temp << 16) | (0xeeull << 24))) {
								if (first_bad_offset == (uint32_t)~0) {
									first_bad_offset = i;
								}
								if (!header_printed) {
									printf("Invalid data on iteration %lld, layer %d, from node=%d on bufferSet %d\n",
									       runningIterCount, syncIterator % NUM_LAYERS, k, bsCtr);
									header_printed = true;
								}

								had_errs = true;
								err_count++;
							} else if (first_good_offset == (uint32_t)~0) {
								first_good_offset = i;
							}
						}

						if (first_bad_offset != (uint32_t)~0) {
							if (mh->verbose_level >= LogSignposts) {
								os_signpost_event_emit(logHandle, badDataSignpost, "MATMUL", "baddata %lu",
								                       first_bad_offset * sizeof(FLOAT_T));
							}
							printf("data at bad offset %zd: 0x%x 0x%x 0x%x ## ", first_bad_offset * sizeof(FLOAT_T),
							       *(uint32_t *)&mat_data[first_bad_offset + 0], *(uint32_t *)&mat_data[first_bad_offset + 1],
							       *(uint32_t *)&mat_data[first_bad_offset + 2]);
							if (first_good_offset != (uint32_t)~0) {
								printf("data at good offset %zd: 0x%x 0x%x 0x%x\n", first_good_offset * sizeof(FLOAT_T),
								       *(uint32_t *)&mat_data[first_good_offset + 0], *(uint32_t *)&mat_data[first_good_offset + 1],
								       *(uint32_t *)&mat_data[first_good_offset + 2]);
							}
						}
						if (exit_on_errs && had_errs) {
							printf("There were errors and exit-on-err was set. (err_count %lld)\n", err_count);
							return -1;
						}
					}

					// clear the block so that the next time around the data
					// has to be transferred or the verification will fail.
					memset(backingDataBuffers[(buffer_idx_offset + syncIterator) % NUM_LAYERS], 0xce,
					       mbs->userBlockSize * myNodeOffset);
					if (mh->verbose_level >= LogSignposts) {
						os_signpost_event_emit(logHandle, verifySignpost, "VerifyEnd", "data len %lld",
						                       mbs->userBlockSize / sizeof(FLOAT_T));
					}
				} // do_verification

				// If we are running over multiple test loops, do not log stats,
				// instead we log stats at the end of the test loop
				if (test_loop_count == 1) {
					if (mh->verbose_level >= LogSignposts) {
						// periodically log stats on sync performance.
						os_signpost_event_emit(logHandle, statsSignpost, "StatsStart", "nada");
					}

					log_stats(mh, mbs, false);

					if (mh->verbose_level >= LogSignposts) {
						os_signpost_event_emit(logHandle, statsSignpost, "StatsEnd", "nada");
					}
				}

				syncIterator++;
			} // while (keep_going && syncIterator < numSyncs)
		} // for (auto bsCtr = 0; bsCtr < bufferSetCount; bsCtr++) {

		// It is safe to move syncs (numSyncs) now towards maximum syncs (max_iter)
		// based on the number of syncs done for this cycle.
		runningIterCount += numSyncs;
	} // while (keep_going && (max_iters == 0 || (total_iters < max_iters))) {

	if (log_latencies) {
		write_data_to_file(sync_durations);
	}

	printf("LLM worker all done after %lld iterations.\n", runningIterCount);

	MeshLogStats(mh, 10);

	return (err_count == 0) ? 0 : -1;
}

void *
worker_rt_thread(void *)
{
	while (!rtThreadReady) {
		usleep(10);
	}

	uint64_t startTime     = 0;
	uint64_t endTime       = 0;
	uint64_t origStartTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);

	for (uint32_t tlCtr = 0; tlCtr < test_loop_count; tlCtr++) {
		uint64_t sendAllBufferId = do_send_to_all ? sendToAllBufferMask + globalBufferId : 0;
		globalBufferId++;

		if (tlCtr > 0) {
			MeshStartReaders(global_mh);
		}

		startTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);

		if (do_send_to_all) { // if the zeroth node is not in the mask, then skip this call
			                  // Make the send to all buffer
			if (MeshSetupSendToAllBufferEx(global_mh, nodeMask, sendAllBufferId, sendToAllBuf, sendToAllBufSize) != 0) {
				printf("Failed to setup send to all buffers.\n");
				exit(99);
			}
		}
		// Make the scatter to all buffer
		uint64_t scatterAllBufferId = 0;
#if 0
		scatterAllBufferId = scatterToAllBufferMask + globalBufferId;
		globalBufferId++;
		MeshSetupScatterToAllBuffer(mh, scatterAllBufferId, scatterToAllBuf, scatterToAllBufSize);
#endif

		// Make the Sync Buffers
		MeshBufferSet_t * bufferSets = (MeshBufferSet_t *)calloc(bufferSetCount, sizeof(MeshBufferSet_t));
		for (uint32_t i = 0; i < bufferSetCount; i++) {
			bufferSets[i].bufferId   = globalBufferId;
			bufferSets[i].bufferSize = bufferSize;
			bufferSets[i].blockSize  = blockSize;
			bufferSets[i].chunkSize  = chunkSize;
			bufferSets[i].numBuffers = numBuffers;

			// TODO: maybe we can just pass in backingDataBuffers instead
			// of doing this indirection.
			bufferSets[i].bufferPtrs = &(cioMeshBufferPtrs[i * numBuffers]);
			bufferSets[i].nodeMask   = nodeMask;
			bufferSets[i].mbs        = nullptr;

			globalBufferId += numBuffers;
			MeshSetupBuffersHint(global_mh, bufferSize);
		}

		printf("About to setup buffers...\n");
		auto res = MeshSetupBufferEx(global_mh, bufferSets, (uint16_t)bufferSetCount);
		if (res != 0) {
			printf("Bah Humbug!  Failed to setup the buffers: %d\n", res);
			exit(99);
		}

		if (copyNetRx) {
			for (int i = 0; i < bufferSetCount; i++) {
				MeshSetupBufferForSelfCopy_private(global_mh, bufferSets[i].mbs);
			}
		}

		if (llm_worker(global_mh, sendAllBufferId, scatterAllBufferId, bufferSets) != 0) {
			exit(5);
		}

		endTime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);

		usleep(10000);
		for (uint32_t i = 0; i < bufferSetCount; i++) {
			printf("========= Log stats for BufferSet: %d =========\n", i);
			log_stats(global_mh, bufferSets[i].mbs, true);
		}

		printf("starting clean up ======================================================\n");
		// Clean up sync
		for (uint32_t i = 0; i < bufferSetCount; i++) {
			MeshReleaseBuffers(global_mh, bufferSets[i].mbs);
		}

		// Clean up ScatterAll
		if (scatterAllBufferId != 0) {
			MeshReleaseBuffer(global_mh, scatterAllBufferId, scatterToAllBufSize);
			scatterAllBufferId = 0;
		}

		// Clean up SendAll
		if (sendAllBufferId != 0) {
			MeshReleaseBuffer(global_mh, sendAllBufferId, sendToAllBufSize);
			sendAllBufferId = 0;
		}
		if (test_loop_count > 1) {
			printf("Iteration run time: %6.2f seconds.\n", (double)(endTime - startTime) / (double)kNsPerSecond);
			printf("================== finished iteration %d ========================\n", tlCtr + 1);
		}
	}

	if (!MeshStopReaders(global_mh)) {
		printf("Failed to stop MeshReaders\n");
	}
	MeshDestroyHandle(global_mh);
	printf("Worker RT thread finished\n");

	printf("Encountered %lld errors\n", err_count);
	printf("Sent %lld bytes of data.\n", bytes_sent);
	printf("Received %lld bytes of data.\n", bytes_sent);
	printf("Total run time: %6.2f seconds.\n", (double)(endTime - origStartTime) / (double)kNsPerSecond);
	printf("Exiting.\n");
	exit((int)err_count);

	return nullptr;
}

static void *
allocateBuffer(uint64_t bufferSize)
{
	uint8_t * buffer;
	if (posix_memalign((void **)&buffer, 1 << 14, bufferSize) != 0) {
		fprintf(stderr, "failed to allocate memaligned buffer\n");
		return NULL;
	};

	printf("llmsim - Buffer starts at %p and ends at %p\n", buffer, buffer + bufferSize);

	// make sure all the memory is present so that the cost of faulting
	// in the pages isn't paid for by other code.
	memset(buffer, 0xa5, bufferSize);

	return buffer;
}

#define DEFAULT_LLM_BUFFER_ID 0x8000 // just a value

int smoke_test_main(int argc, char * argv[]);

int
main(int argc, char ** argv)
{
	bool doBarrier = true;

	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "-smoketest") == 0) {
			return smoke_test_main(argc - 1, argv + 1);
		} else if (strcmp(argv[i], "-bsize") == 0 && i + 1 < argc) {
			blockSize = (uint32_t)getArg(argv[i + 1]);
			i++;
		} else if (strcmp(argv[i], "-numnodes") == 0 && i + 1 < argc) {
			nodeCount = (uint32_t)getArg(argv[i + 1]);
			i++;
		} else if (strcmp(argv[i], "-delay") == 0 && i + 1 < argc) {
			usleep_delay = (uint32_t)getArg(argv[i + 1]);
			i++;
			printf("Delay set to %d\n", usleep_delay);
		} else if (strcmp(argv[i], "-csize") == 0 && i + 1 < argc) {
			chunkSize = (uint32_t)getArg(argv[i + 1]);
			i++;
			printf("Chunk size set to %d\n", chunkSize);
		} else if (strcmp(argv[i], "-maxiter") == 0 && i + 1 < argc) {
			max_iters = (uint64_t)getArg(argv[i + 1]);
			printf("Will run for %lld iterations\n", max_iters);
			i++;
		} else if (strcmp(argv[i], "-testloop") == 0 && i + 1 < argc) {
			test_loop_count = (uint32_t)getArg(argv[i + 1]);
			printf("Will loop over %u test iterations\n", test_loop_count);
			i++;
		} else if (strcmp(argv[i], "-nobarrier") == 0) {
			doBarrier = false;
		} else if (strcmp(argv[i], "-nogpu") == 0) {
			// we don't do any gpu work any more anyway
			// but we'll leave the option for compatibility
			do_gpu_work = false;
		} else if (strcmp(argv[i], "-noverify") == 0) {
			printf("Will NOT do any data verification\n");
			do_verification = false;
		} else if (strcmp(argv[i], "-nosendtoall") == 0) {
			do_send_to_all = false;
		} else if (strcmp(argv[i], "-exitonerr") == 0) {
			printf("Will exit on errors.\n");
			exit_on_errs = true;
		} else if (strcmp(argv[i], "-key") == 0 && i + 1 < argc) {
			crypto_key = argv[i + 1];
			if (strlen(crypto_key) != 32) {
				printf("Crypto key must be at exactly 16 bytes long\n");
				exit(1);
			}
			// printf("Crypto Key set to: %s\n", crypto_key);
			i++;
		} else if (strcmp(argv[i], "-buffersets") == 0 && i + 1 < argc) {
			bufferSetCount = (uint32_t)getArg(argv[i + 1]);
			printf("Running with %u buffer sets\n", bufferSetCount);
			i++;
		} else if (strcmp(argv[i], "-sendtoallbsize") == 0 && i + 1 < argc) {
			sendToAllBufSize = (uint32_t)getArg(argv[i + 1]);
			i++;
		} else if (strcmp(argv[i], "-nodemask") == 0 && i + 1 < argc) {
			nodeMask = getArg(argv[i + 1]);
			printf("Using nodemask: 0x%x\n", nodeMask);
			i++;
		} else if (strcmp(argv[i], "-copynetrx") == 0) {
			printf("Will copy current node's block into all sections.\n");
			copyNetRx = true;
		} else if (strcmp(argv[i], "-syncsiter") == 0 && i + 1 < argc) {
			num_syncs_per_iter = getArg(argv[i + 1]);
			printf("Setting nums syncs per iter: %d\n", num_syncs_per_iter);
			i++;
		} else if (strcmp(argv[i], "-overridepartition") == 0 && i + 1 < argc) {
			overridePartition = getArg(argv[i + 1]);
			printf("Overriding partition index to: %d\n", overridePartition);
			i++;
		} else if (strcmp(argv[i], "-loglatencies") == 0 && i + 1 < argc) {
			log_latencies = true;
			i++;
			latency_log_file = argv[i];
			i++;
		} else {
			printf("Unknown argument: %s\n", argv[i]);
		}
	}

	uint32_t driverNodeId;
	if (!MeshGetInfo(&driverNodeId, &nodeCount)) {
		printf("Could not get basic info about my node-id or the number of nodes.  Fail.\n");
		exit(1);
	}

	printf("Node count is %d\n", nodeCount);

	myNodeId = driverNodeId;

	if (myNodeId == (uint32_t)~0 || nodeCount == 0) {
		usage(argv[0]);
		exit(1);
	}

	if (blockSize == 0) {
		blockSize = DEFAULT_BLOCK_SIZE;
		printf("Using default block size of %lldk\n", blockSize / 1024);
	}

	//
	// Here is where we create a MeshHandle, setup the buffers and
	// get read to start doing work.
	//
	MeshHandle_t * mh;

	// char * cryptoState = getenv("MESH_CRYPTO");

	const char * defaultCryptoKey = "123456789abcdef0123456789abcdef0";
	if (crypto_key != NULL) {
		if (strlen(crypto_key) == 0) {
			printf("Clearing the crypto key\n");
		} else {
			printf("Setting crypto key to %s\n", crypto_key);
		}
		MeshSetCryptoKey(crypto_key, strlen(crypto_key));
	} else {
		printf("Using default crypto key '%s'\n", defaultCryptoKey);
		MeshSetCryptoKey(defaultCryptoKey, strlen(defaultCryptoKey));
	}

	if (overridePartition == -1) {
		mh = MeshCreateHandle(leaderNodeId);
	} else {
		mh = MeshCreateHandleWithPartition_private(leaderNodeId, (uint8_t)overridePartition);
	}

	if (!mh) {
		printf("Could not setup the mesh.\n");
		exit(2);
	}

	const uint8_t participatingNodeCount = getNodeCountFromMask(nodeMask);
	printf("participatingNodeCount is %d\n", participatingNodeCount);

	if (!isNodeParticipating(myNodeId, nodeMask)) {
		printf("Node is not participating in this work, exiting\n");
		// exit(0);
	}

	bufferSize = (participatingNodeCount * blockSize);
	if (chunkSize == 0) {
		// Copy from MeshSetupBuffers
		if (blockSize <= 128 * 1024) {
			chunkSize = blockSize;
		} else if (blockSize <= 256 * 1024) {
			chunkSize = blockSize / 2;
		} else {
			chunkSize = blockSize / 4;
		}
	}

	printf("llmsim using bufferSize %lld blockSize %lld chunkSize %lld\n", bufferSize, blockSize, chunkSize);

	global_mh = mh; // only for the sigint handler
	signal(SIGINT, llmsimSigIntHandler);

	MeshStartReaders(mh);

	//
	// These are the app buffers.  These are shared with CIOMesh as it loops
	// through its buffer sets.
	//
	cioMeshBufferPtrs = (void **)calloc(numBuffers * bufferSetCount, sizeof(void *));
	if (cioMeshBufferPtrs == NULL) {
		printf("No memory for buffer pointers?!\n");
		exit(1);
	}

	// We will only have 1 source of backing buffers and even though we have
	// multiple bufferSets, we will use the same backing buffers.

	// First allocate the backing buffers.
	for (uint32_t i = 0; i < numBuffers; i++) {
		void * bptr;

		// the buffer is sized to accomodate the results from each node
		backingDataBuffers[i] = bptr = malloc(blockSize * participatingNodeCount);

		int ret = mlock(cioMeshBufferPtrs[i], blockSize * participatingNodeCount);
		if (ret != 0) {
			printf("mlock() of bufferPtrs[%d] %p / %p / %lld failed ret=%d\n", i, cioMeshBufferPtrs[i], bptr,
			       blockSize * participatingNodeCount, ret);
		}

		// clear the entire buffer so that we know if data syncs before it was supposed to
		memset(bptr, (int)(0xa0 | mh->myNodeId), blockSize * participatingNodeCount);
	}

	// Next assign the CIOMesh buffer pointers to the backing buffers
	for (uint32_t i = 0; i < bufferSetCount; i++) {
		for (uint32_t j = 0; j < numBuffers; j++) {
			cioMeshBufferPtrs[(i * numBuffers) + j] = backingDataBuffers[j];
		}
	}

	sendToAllBuf = allocateBuffer(sendToAllBufSize);
	if (sendToAllBuf == NULL) {
		printf("no memory for the send-to-all buffer.\n");
		exit(3);
	}

	uint32_t n = 0;
	for (uint64_t j = 0; j < sendToAllBufSize; j += sendToAllBufSize / participatingNodeCount, n++) {
		// make sure each node gets something different
		memset((char *)sendToAllBuf + j, (int)(0x80 | n), sendToAllBufSize / participatingNodeCount);
	}

	// Scatter-To-All buffer Allocation
	if ((scatterToAllBufSize % nodeCount) != 0) {
		scatterToAllBufSize = (1024 * 1024 * nodeCount);
		printf("scatterToAllBufSize %lld isn't evenly divisble by the nodeCount %d. adjusting it\n", scatterToAllBufSize,
		       nodeCount);
	}

	scatterToAllBuf = allocateBuffer(scatterToAllBufSize);
	if (sendToAllBuf == NULL) {
		printf("no memory for the scatter buffer.\n");
		exit(3);
	}

	n = 0;
	for (uint64_t j = 0; j < scatterToAllBufSize; j += scatterToAllBufSize / nodeCount, n++) {
		// make sure each node gets something different
		memset((char *)scatterToAllBuf + j, (int)(0xf0 | n), scatterToAllBufSize / nodeCount);
	}

	MeshSetMaxTimeout(mh, 0);

	int ret = 0;

	if (doBarrier) {
		printf("Initial Barrier Sync\n");
		ret = MeshBarrier(mh);
		if (ret != 0) {
			printf("Barrier Sync failed with ret=%d\n", ret);
			exit(5);
		} else {
			printf("Barrier Sync finished\n");
		}
	} else {
		printf("Skipped initial barrier.\n");
	}

	MeshSetMaxTimeout(mh, (int64_t)kNsPerSecond * 10);

	printf("Starting the simulation....\n");

	pthread_t rtLLMThread;

	pthread_attr_t threadAttributes;
	int error = pthread_attr_init(&threadAttributes);
	if (error) {
		fprintf(stderr, "Failed to initialize pthread attributes");
		return 1;
	}

	sched_param schedulingParams;
	error = pthread_attr_getschedparam(&threadAttributes, &schedulingParams);
	if (error) {
		fprintf(stderr, "Failed to get pthread scheduler param");
		return 1;
	}

	schedulingParams.sched_priority = 31;
	error                           = pthread_attr_setschedparam(&threadAttributes, &schedulingParams);
	if (error) {
		fprintf(stderr, "Failed to set pthread scheduler param");
		return 1;
	}

	error = pthread_attr_setschedpolicy(&threadAttributes, SCHED_RR);
	if (error) {
		fprintf(stderr, "Failed to set pthread scheduler policy to FIFO");
		return 1;
	}

	pthread_create(&rtLLMThread, &threadAttributes, &worker_rt_thread, nullptr);

	rtThreadReady = true;

	dispatch_main();

	return 0;
}
