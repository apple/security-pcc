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

//
//  BridgingHeader.m
//  DarwinInit
//

#include "BridgingHeader.h"
#include "SecureConfigDB/secureconfig.h"

#import <os/log.h>
#import <Foundation/Foundation.h>
#import <SoftLinking/SoftLinking.h>

#include <image4/trust.h>
#include <image4/trust_evaluation.h>
#include <image4/environment.h>

SOFT_LINK_DYLIB(libcryptex);
SOFT_LINK_FUNCTION(libcryptex, cryptex_lockdown, cryptex_lockdown, errno_t, (void), ());

bool shim_check_tailspin(void) {
	return libtailspinLibrary();
}

bool shim_allows_internal_security_policies(void) {
    return os_variant_allows_internal_security_policies(NULL);
}

bool shim_WIFSIGNALED(int32_t status) {
    return WIFSIGNALED(status);
}

int shim_WTERMSIG(int32_t status) {
    return WTERMSIG(status);
}

bool shim_WIFEXITED(int32_t status) {
    return WIFEXITED(status);
}

int shim_WEXITSTATUS(int32_t status) {
    return WEXITSTATUS(status);
}

int shim_reboot3(uint64_t flag) {
    return reboot3(flag);
}

int shim_reboot3_with_purpose(uint64_t flag, rb3_userreboot_purpose_t_t purpose) {
    return reboot3(flag, purpose);
}

int64_t shim_MGQUniqueChipID(void) {
    return MGGetSInt64Answer(kMGQUniqueChipID, -1);
}

NSString *shim_MGQSerialNumber(void) {
    return (__bridge_transfer NSString *)MGGetStringAnswer(kMGQSerialNumber);
}

NSNumber *shim_MGQOceanComputeCarrierID(void) {
    return (__bridge_transfer NSNumber *)MGCopyAnswer(kMGQOceanComputeCarrierID, NULL);
}

NSNumber *shim_MGQOceanComputeCarrierSlot(void) {
    return (__bridge_transfer NSNumber *)MGCopyAnswer(kMGQOceanComputeCarrierSlot, NULL);
}

int64_t shim_MGQChipID(void) {
    return MGGetSInt64Answer(kMGQChipID, -1);
}

int64_t shim_MGQBoardID(void) {
    return MGGetSInt64Answer(kMGQBoardId, -1);
}

int64_t shim_MGQSecurityDomain(void) {
    return MGGetSInt64Answer(kMGQSecurityDomain, -1);
}

uint8_t* shim_MGPROD_E126B(void) {
    static typeof(MGPROD_E126B) result = MGPROD_E126B;
    return result;
}

uint8_t* shim_MGPROD_E126T(void) {
    static typeof(MGPROD_E126T) result = MGPROD_E126T;
    return result;
}

uint8_t* shim_MGPROD_E130(void) {
    static typeof(MGPROD_E130) result = MGPROD_E130;
    return result;
}

bool shim_TMSetupTime(void) {
#define QUEUE_NAME "com.apple.darwinit-time-sync"
    __block bool time_ready = false;
    NSInteger timeout = 60;
    dispatch_queue_t q = dispatch_queue_create(QUEUE_NAME, NULL);

    dispatch_group_t dg = dispatch_group_create();
    dispatch_group_enter(dg);

    TMSetupTime(q, timeout, ^(CFErrorRef error) {
        if (error) {
            os_log_fault(OS_LOG_DEFAULT, "Failed time sync with error %@",
                   error);
        } else {
            time_ready = true;
        }
        dispatch_group_leave(dg);
    });

    dispatch_group_wait(dg, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC));

    return time_ready;
#undef QUEUE_NAME
}

#if TARGET_OS_OSX
bool support_package_install(void) {
	return [PKPackage class] != nil && [PKDistributionController class] != nil;
}
#endif

int shim_register_config(NSData *data) {
    int ret = register_config_from_buffer(data.bytes, data.length, "darwin-init", "application/json");

    if (ret) {
        os_log_error(OS_LOG_DEFAULT,
                "Failed to register_config_from_buffer with error %d", ret);
    }

    return ret;
}

int shim_register_secureconfig_parameters(NSData *data,
		NSString *securityPolicy) {
	int ret = register_config_parameters(data.bytes, data.length,
			securityPolicy.UTF8String);

	if (ret) {
		os_log_error(OS_LOG_DEFAULT, "register_config_parameters() failed with error %d", ret);
	}

	return ret;
}

int shim_kIOReturnNoResources(void) {
    return kIOReturnNoResources;
}

NSString *shim_automatedDeviceGroup(void) {
	return [OSASystemConfiguration automatedDeviceGroup];
}

void shim_setAutomatedDeviceGroup(NSString *automatedDeviceGroup) {
	[OSASystemConfiguration setAutomatedDeviceGroup:automatedDeviceGroup];
}

errno_t shim_cryptex_lockdown(void) {
    return cryptex_lockdown();
}

static void
image4_trust_result(const image4_trust_t *trst,
		const void *result, size_t result_len,
		errno_t error, void *_ctx)
{
	errno_t *image4_error = (errno_t *)_ctx;
	*image4_error = error;
}

bool shim_validateImage4Ticket(const void * _Nonnull manifest, size_t manifest_len, const void * _Nonnull ginf, size_t ginf_len) {
	errno_t image4_error = -1;
	image4_environment_t *env = image4_environment_new(IMAGE4_COPROCESSOR_CRYPTEX1, IMAGE4_COPROCESSOR_HANDLE_CRYPTEX1_GENERIC);
	image4_trust_t *trust = image4_trust_new(env, IMAGE4_TRUST_EVALUATION_EXEC, manifest, manifest_len, IMAGE4_TRUST_FLAG_INIT);
	image4_trust_set_payload(trust, 'ginf', ginf, ginf_len);

	uint64_t ndom = 0;
	uint8_t *d;
	size_t d_len = 0;

	image4_trust_record_property_integer(trust, IMAGE4_TRUST_SECTION_MANIFEST, 'ndom', &ndom, nil);
	image4_trust_record_property_data(trust, IMAGE4_TRUST_SECTION_MANIFEST, 'cnch', (void **)&d, &d_len);

	image4_trust_evaluate(trust, &image4_error, &image4_trust_result);

	if (image4_error) {
		os_log_error(OS_LOG_DEFAULT, "image4_trust_evaluate returned nonzero exit code %d", image4_error);
		goto _exit;
	}

	uint8_t d_host[IMAGE4_DIGEST_MAX_LEN] = {0};
	size_t d_host_len = IMAGE4_DIGEST_MAX_LEN;

	os_log_info(OS_LOG_DEFAULT, "fetched ndom %llu", ndom);
	image4_environment_set_nonce_domain(env, ndom);
	image4_error = image4_environment_copy_nonce_digest(env, &d_host, &d_host_len);

//add explicit error for copy digest
	if (image4_error) {
		os_log_error(OS_LOG_DEFAULT, "image4_environment_copy_nonce_digest returned nonzero exit code %d", image4_error);
		goto _exit;
	}

	os_log_info(OS_LOG_DEFAULT, "manifest cnch len is %zu, env cnch lenth is %zu", d_len, d_host_len);

	if (!((d_len == d_host_len) && (memcmp(d, d_host, d_host_len) == 0))) {
		os_log_error(OS_LOG_DEFAULT, "Nonces did not match");
		image4_error = 1;
	}

_exit:
	image4_environment_destroy(&env);
	image4_trust_destroy(&trust);
	return image4_error == 0;
}
