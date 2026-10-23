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

#pragma once

#include <sys/kdebug.h>

// These #defines are used in the meta parameter for various traces
// They should match the plist.

#define SEND_META_SEND_AND_PREPARE 0
#define SEND_META_SEND_CHUNK 1
#define SEND_META_CHUNK_PREPARED 2
#define SEND_META_CHUNK_DISPATCHED 3
#define SEND_META_COMMANDEER_SEND_COMPLETE 4
#define SEND_META_SEND_COMPLETE 5
#define SEND_META_USER_SPACE_RETURN 6

#define TRANSMIT_QUEUE_META_PRE_PIO_WRITE_ALL 0
#define TRANSMIT_QUEUE_META_POST_PIO_WRITE_ALL 1
#define TRANSMIT_QUEUE_META_PRE_PIO_WRITE_PARTIAL 2
#define TRANSMIT_QUEUE_META_POST_PIO_WRITE_PARTIAL 3
#define TRANSMIT_QUEUE_META_PRE_SUBMIT 4
#define TRANSMIT_QUEUE_META_POST_SUBMIT 5

#define COMMANDEER_SEND_META_NOT_DISPATCHED 0
#define COMMANDEER_SEND_META_CHECK_READY 1
#define COMMANDEER_SEND_META_COMPLETE 2

#define RECEIVE_BATCH_META_ENTRY 0
#define RECEIVE_BATCH_META_EXIT 1
#define RECEIVE_BATCH_META_EARLY_EXIT 2
#define RECEIVE_BATCH_META_BEGIN_READS 3
#define RECEIVE_BATCH_META_READING_OFFSET 4

#ifdef DEBUG_SIGNPOSTS

extern bool gSignpostsEnabled;

#define APPLECIOMESH_COMPONENT 192

#define APPLECIOMESH_TRACE(code, a, b, c, d) KDBG(ARIADNEDBG_CODE(APPLECIOMESH_COMPONENT, code), a, b, c, d)

// RESERVED 1
// RESERVED 2

// General
#define SEND_CODE 3
#define LINK_DATA_SENT_CALLBACK_CODE 4
#define LINK_DATA_RECEIVED_CALLBACK_CODE 5
#define ALL_LINKS_DATA_SENT_CODE 6
#define TRANSMIT_QUEUE_CODE 7
#define TX_CHUNK_PREPARED_CODE 8
#define RX_CHUNK_PREPARED_CODE 9
#define RECEIVE_BATCH_CODE 10

// Flow Control Commands
#define RX_COMMAND_RECEIVED_CODE 20
#define TX_COMMAND_SENT_CODE 21

// Forward
#define FORWARD_RX_RECEIVED_CODE 31
#define FORWARD_TX_AVAILABLE_CODE 32
#define FORWARD_STARTED_CODE 33
#define FORWARD_COMPLETED_CODE 34
#define FORWARD_PREPARED_CODE 35
#define FORWARD_PREVIOUS_ACTION_COMPLETE_CODE 36
#define FORWARD_TX_FLOW_COMPLETE_CODE 37

// Commandeer
#define COMMANDEER_SEND_CODE 41
#define COMMANDEER_PREPARE_CODE 42
#define COMMANDEER_FORWARD_CODE 43

#define TEST_CODE 99

// Trace macros

#define SEND_TR(bufferId, offset, meta)                               \
	{                                                                 \
		if (gSignpostsEnabled)                                        \
			APPLECIOMESH_TRACE(SEND_CODE, bufferId, offset, meta, 0); \
	}

#define LINK_DATA_SENT_CALLBACK_TR(link, bufferId, offset)                               \
	{                                                                                    \
		if (gSignpostsEnabled)                                                           \
			APPLECIOMESH_TRACE(LINK_DATA_SENT_CALLBACK_CODE, link, bufferId, offset, 0); \
	}
#define LINK_DATA_RECEIVED_CALLBACK_TR(link, bufferId, offset)                               \
	{                                                                                        \
		if (gSignpostsEnabled)                                                               \
			APPLECIOMESH_TRACE(LINK_DATA_RECEIVED_CALLBACK_CODE, link, bufferId, offset, 0); \
	}
#define ALL_LINKS_DATA_SENT_TR(bufferId, offset)                                  \
	{                                                                             \
		if (gSignpostsEnabled)                                                    \
			APPLECIOMESH_TRACE(ALL_LINKS_DATA_SENT_CODE, bufferId, offset, 0, 0); \
	}
#define TRANSMIT_QUEUE_TR(link, offset, meta)                               \
	{                                                                       \
		if (gSignpostsEnabled)                                              \
			APPLECIOMESH_TRACE(TRANSMIT_QUEUE_CODE, link, meta, offset, 0); \
	}
#define TX_CHUNK_PREPARED_TR(bufferId, offset, sendMask)                               \
	{                                                                                  \
		if (gSignpostsEnabled)                                                         \
			APPLECIOMESH_TRACE(TX_CHUNK_PREPARED_CODE, bufferId, offset, sendMask, 0); \
	}
#define RX_CHUNK_PREPARED_TR(link, bufferId, offset)                               \
	{                                                                              \
		if (gSignpostsEnabled)                                                     \
			APPLECIOMESH_TRACE(RX_CHUNK_PREPARED_CODE, link, bufferId, offset, 0); \
	}
#define RECEIVE_BATCH_TR(bufferId, meta, extra)                               \
	{                                                                         \
		if (gSignpostsEnabled)                                                \
			APPLECIOMESH_TRACE(RECEIVE_BATCH_CODE, bufferId, meta, extra, 0); \
	}

#define RX_COMMAND_RECEIVED_TR(link, bufferId, offset, commandIdx)                            \
	{                                                                                         \
		if (gSignpostsEnabled)                                                                \
			APPLECIOMESH_TRACE(RX_COMMAND_RECEIVED_CODE, link, bufferId, offset, commandIdx); \
	}
#define TX_COMMAND_SENT_TR(link, bufferId, offset, commandIdx)                            \
	{                                                                                     \
		if (gSignpostsEnabled)                                                            \
			APPLECIOMESH_TRACE(TX_COMMAND_SENT_CODE, link, bufferId, offset, commandIdx); \
	}

#define FORWARD_RX_RECEIVED_TR(link, sourceNode, buffer, offset)                            \
	{                                                                                       \
		if (gSignpostsEnabled)                                                              \
			APPLECIOMESH_TRACE(FORWARD_RX_RECEIVED_CODE, link, sourceNode, buffer, offset); \
	}
#define FORWARD_TX_AVAILABLE_TR(link, sourceNode, buffer, offset)                            \
	{                                                                                        \
		if (gSignpostsEnabled)                                                               \
			APPLECIOMESH_TRACE(FORWARD_TX_AVAILABLE_CODE, link, sourceNode, buffer, offset); \
	}
#define FORWARD_STARTED_TR(link, buffer, offset, commandCount)                            \
	{                                                                                     \
		if (gSignpostsEnabled)                                                            \
			APPLECIOMESH_TRACE(FORWARD_STARTED_CODE, link, buffer, offset, commandCount); \
	}
#define FORWARD_COMPLETED_TR(link, remainingElements, buffer, offset)                            \
	{                                                                                            \
		if (gSignpostsEnabled)                                                                   \
			APPLECIOMESH_TRACE(FORWARD_COMPLETED_CODE, link, remainingElements, buffer, offset); \
	}
#define FORWARD_PREPARED_TR(link, chainElement, buffer, offset)                            \
	{                                                                                      \
		if (gSignpostsEnabled)                                                             \
			APPLECIOMESH_TRACE(FORWARD_PREPARED_CODE, link, chainElement, buffer, offset); \
	}
#define FORWARD_PREVIOUS_ACTION_COMPLETE_TR(link, sourceNode, buffer, offset)
#define FORWARD_TX_FLOW_COMPLETE_TR(link, numCommandsComplete, buffer, offset)

#define COMMANDEER_SEND_TR(buffer, offset, meta)                               \
	{                                                                          \
		if (gSignpostsEnabled)                                                 \
			APPLECIOMESH_TRACE(COMMANDEER_SEND_CODE, buffer, offset, meta, 0); \
	}
#define COMMANDEER_FORWARD_TR(link, buffer, offset, meta)                            \
	{                                                                                \
		if (gSignpostsEnabled)                                                       \
			APPLECIOMESH_TRACE(COMMANDEER_FORWARD_CODE, link, buffer, offset, meta); \
	}
#define TEST_TR(a, b, c, d)                            \
	{                                                  \
		if (gSignpostsEnabled)                         \
			APPLECIOMESH_TRACE(TEST_CODE, a, b, c, d); \
	}

#else

#define SEND_TR(bufferId, offset, meta)
#define LINK_DATA_SENT_CALLBACK_TR(link, bufferId, offset)
#define LINK_DATA_RECEIVED_CALLBACK_TR(link, bufferId, offset)
#define ALL_LINKS_DATA_SENT_TR(bufferId, offset)
#define TRANSMIT_QUEUE_TR(link, offset, meta)
#define TX_CHUNK_PREPARED_TR(bufferId, offset, sendMask)
#define RX_CHUNK_PREPARED_TR(link, bufferId, offset)
#define RECEIVE_BATCH_TR(bufferId, meta, extra)
#define RX_COMMAND_RECEIVED_TR(link, bufferId, offset, commandIdx)
#define TX_COMMAND_SENT_TR(link, bufferId, offset, commandIdx)
#define FORWARD_RX_RECEIVED_TR(link, sourceNode, buffer, offset)
#define FORWARD_TX_AVAILABLE_TR(link, sourceNode, buffer, offset)
#define FORWARD_STARTED_TR(link, buffer, offset, commandCount)
#define FORWARD_COMPLETED_TR(link, remainingElements, buffer, offset)
#define FORWARD_PREPARED_TR(link, chainElement, buffer, offset)
#define FORWARD_PREVIOUS_ACTION_COMPLETE_TR(link, sourceNode, buffer, offset)
#define FORWARD_TX_FLOW_COMPLETE_TR(link, numCommandsComplete, buffer, offset)

#define COMMANDEER_SEND_TR(buffer, offset, meta)
#define COMMANDEER_FORWARD_TR(link, buffer, offset, meta)
#define TEST_TR(a, b, c, d)

#endif
