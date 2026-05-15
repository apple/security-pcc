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

#pragma once

#include <IOKit/thunderbolt/IOThunderboltFamilyCommon.h>
#include <stddef.h>
#include <stdint.h>

const uint32_t kTxRingSize        = 4096;
const uint32_t kRxRingSize        = 4096;
const uint32_t kTxInterruptStride = 128;
const uint32_t kRxInterruptStride = 128;
const bool kE2EFlowControlEnable  = true;

const uint32_t kControlCredits         = 5;
const uint32_t kControlPriority        = 5;
const uint32_t kControlInterruptStride = 32;

const size_t kCIOPageAlignmentLeadingZeroBits  = 14;
const size_t kCIOFrameAlignmentLeadingZeroBits = 12;

const size_t kMaxAssignmentCount = 512;

// The real trailer size.
const uint32_t kTrailerSize = 256;
// The trailer size in frames to avoid double buffering in NHI.
const uint32_t kTrailerFrameSize = kIOThunderboltMaxFrameSize;

const uint32_t kMaxTBTCommandCount = 8;

const uint32_t kStartForwardCommandIndex = 0;
const uint32_t kSmallMinimumForwardSize  = 2 * kIOThunderboltMaxFrameSize;
const uint32_t kLargeMinimumForwardSize  = 2 * kIOThunderboltMaxFrameSize;

// This needs to match the IOKit matching rules in Info.plist.
#define XD_PROTOCOL_KEY_STRING "ciomesh"

const uint32_t kMaxMeshLinkCount = 8;
const uint32_t kNumDataPaths     = 2;

const uint32_t kMaxMeshLinksPerChannel = 2;
const uint32_t kMaxMeshChannelCount    = kMaxMeshLinkCount / kMaxMeshLinksPerChannel;

const uint32_t kNumControlCommands     = 0xFF;
const uint32_t kCommandBufferSize      = 4096;
const uint32_t kCommandSize            = 128;
const uint32_t kCommandDataSize        = kCommandSize - 4;
const uint32_t kCommandMessageDataSize = kCommandBufferSize - kCommandSize;
const uint32_t kSOF                    = 1;
const uint32_t kEOF                    = 2;

const uint32_t kNumBulkPrepare         = 0xFF;
const uint64_t kMaxCommandeerWaitCount = 100'000'000;

const uint32_t kLinkEventSize     = 32;
const uint32_t kLinkEventDataSize = kLinkEventSize - 4;
const uint32_t kLinkEventCount    = 1024;

const uint32_t kMaxWaitTimeInSeconds = 30;

// note: if this ever changes, also go update AppleCIOMeshAPIPrivate.h
const uint32_t kMaxCIOMeshNodes = 8;
// note: if this ever changes, also go update AppleCIOMeshAPIPrivate.h
const uint32_t kMaxExtendedMeshNodes = 32;
#define MAX_NODES_DEFINED 1

const uint32_t kForwardNodeCount       = 3;
const uint32_t kMaxForwardAction       = 3072;
const uint32_t kMaxForwardChainElement = kMaxForwardAction / kForwardNodeCount;
const uint32_t kForwardQueueCount      = 0xFF;

// note: if this ever changes, also go update AppleCIOMeshAPIPrivate.h
const uint32_t kMaxPartitions            = 4;
const uint32_t kMaxForwardElementActions = 256 * kMaxPartitions; // 128 Chunks/Block * 2 Links/Channel is the max.
const uint32_t kMaxForwardChainGroup     = kMaxForwardChainElement;

const uint32_t kMaxForwardChains = 128;

const uint32_t kTagSize = 16;

const uint64_t kMaxSecondsPerCryptoKey = 86400;
const uint64_t kMaxBuffersPerCryptoKey = 1000000;

// Let's wait upto 5us at a time when getting data from nodes.
const uint64_t kDefaultMaxWaitBatchNodeNS = 5000;

const uint64_t kMaxNHIQueueByteSize = (15 * 1024 * 1024);
const uint64_t kMaxChunkSize        = (15 * 1024 * 1024);
const uint64_t kMaxChunkSizePerLink = kMaxChunkSize / kMaxMeshLinksPerChannel;
