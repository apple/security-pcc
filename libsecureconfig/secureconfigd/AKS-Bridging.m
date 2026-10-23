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
//  AKS-Bridging.m
//  secureconfigd
//

#import <Foundation/Foundation.h>
#import <AppleKeyStore/libaks.h>
#import <AppleKeyStore/aks_attestation_verify.h>
#import <corecrypto/ccsha2.h>
#import <os/log.h>
#import "secureconfigd-Bridging-Header.h"
// FB8BBEC2-BCC6-4ECC-964A-7BEB0C26674A
//
// Identifier for the sealed hash slot used by secureconfig; this is a stable
// identifier and carries no meaning beyond its uniqueness.
//
// UUID was randomly generated using uuidgen(3)
#define SECURE_CONFIG_SIGNATURE_SEALED_HASH_SLOT (uuid_t){ \
	0xFB, 0x8B, 0xBE, 0xC2, 0xBC, 0xC6, 0x4E, 0xCC, \
	0x96, 0x4A, 0x7B, 0xEB, 0x0C, 0x26, 0x67, 0x4A, \
}

NSData*
create_digest_for_configs(NSData *entry) {
	NSData *retVal = nil;
	uint8_t hash[CCSHA384_OUTPUT_SIZE] = { 0 };
	const struct ccdigest_info *digest = NULL;
	digest = ccsha384_di();
	ccdigest_di_decl(digest, ctx);
	ccdigest_init(digest, ctx);
	ccdigest_update(digest, ctx, entry.length, entry.bytes);
	ccdigest_final(digest, ctx, hash);
	os_log(OS_LOG_DEFAULT, "computed manifest hash: %.*P",
			(int)digest->output_size, hash);
	os_log(OS_LOG_DEFAULT, "expected size %zu", digest->output_size);
	retVal = [NSData dataWithBytes:hash length:digest->output_size];
	return retVal;
}

NSData*
record_aks_data_with_flags(NSData* entry, aks_sealed_hash_flags_t flags) {
	kern_return_t kr = KERN_FAILURE;
	NSData *newHash = create_digest_for_configs(entry);

	if (!newHash) {
		os_log_error(OS_LOG_DEFAULT, "Failed to create digest");
		return nil;
	}

	kr = aks_sealed_hashes_set(SECURE_CONFIG_SIGNATURE_SEALED_HASH_SLOT, flags,
							newHash.bytes, newHash.length);
	switch (kr) {
	case kSKSReturnNoSpace:
		// Indicates that all ten slots have been used.
		os_log_error(OS_LOG_DEFAULT, "All slots used");
		break;
	case kSKSReturnReadOnly:
		// Someone else set the slot before us and did not use the ratchet flag.
		os_log_error(OS_LOG_DEFAULT, "unexpected read-only hash slot");
		break;
	default:
		os_log(OS_LOG_DEFAULT, "aks_sealed_hashes_set: %#x", kr);
		break;
	}

	return newHash;
}

NSData*
_shim_aks_ratchet(NSData* entry) {
	return record_aks_data_with_flags(entry, sealed_hash_flag_rachet);
}

NSData*
_shim_aks_record_no_ratchet(NSData* entry) {
	return record_aks_data_with_flags(entry, sealed_hash_flag_none);
}

NSData*
_shim_aks_read_sealed_hash(NSUUID* slot) {
	errno_t err = -1;
	NSData* slotContents = [[NSData alloc] init];
	uuid_t target_slot;
	uint8_t *attestation = NULL;
	size_t attestation_len = 0;
	aks_sealed_hash_value_t sh_value = {};
	uint8_t *dak_pub = NULL;
	size_t dak_pub_len = 0;
	uint8_t raw_context[aks_attest_context_size];
	aks_attest_context_t attest_context = (aks_attest_context_t)&raw_context;
	aks_ref_key_t ref_key = { 0 };

	[slot getUUIDBytes:target_slot];

	err = aks_ref_key_create(bad_keybag_handle, key_class_f, key_type_asym_ec_p256,
			NULL, 0, &ref_key);
	if (err) {
		os_log_error(OS_LOG_DEFAULT,"AKS error creating keybag handle: %d", err);
		goto out;
	}

	err = aks_system_key_attest(aks_system_key_dak, aks_system_key_generation_committed, ref_key, NULL, 0, &attestation, &attestation_len);
	if (err) {
		os_log_error(OS_LOG_DEFAULT,"AKS error getting attestation: %d", err);
		goto out;
	}

	err = aks_system_key_get_public(aks_system_key_dak, aks_system_key_generation_committed, NULL, 0, &dak_pub, &dak_pub_len);
	if (err) {
		os_log_error(OS_LOG_DEFAULT,"AKS error getting system key: %d", err);
		goto out;
	}

	err = aks_attest_context_init(attestation, attestation_len, attest_context);
	if (err) {
		os_log_error(OS_LOG_DEFAULT,"AKS error initializing contexdt: %d", err);
		goto out;
	}

	err = aks_attest_context_verify(attest_context, dak_pub, dak_pub_len);
	if (err) {
		os_log_error(OS_LOG_DEFAULT,"AKS error verifying context %d", err);
		goto out;
	}

	err = aks_attest_context_get_sealed_hash(attest_context, target_slot, &sh_value);
	if (err) {
		os_log_error(OS_LOG_DEFAULT,"AKS error reading sealed hash %@: %d",  [slot UUIDString], err);
		goto out;
	}

	if (sh_value.digest_len > 0) {
		slotContents = [NSData dataWithBytes:sh_value.digest length:sh_value.digest_len];
	}

out:
	return slotContents;
}

NSUUID*
_shim_copy_config_slot_uuid(void) {
	return [[NSUUID alloc] initWithUUIDBytes:SECURE_CONFIG_SIGNATURE_SEALED_HASH_SLOT];
}
