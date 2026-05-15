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
//  BridgingHeader.h
//  darwinOSBits
//

#pragma once

#include <TargetConditionals.h>

#if !TARGET_OS_OSX
#include <IOKit/IOKitLib.h>
#include <IOKit/IOTypes.h>
#endif

#include <archive.h>
#include <archive_entry.h>
#include <reboot2.h>
#import <tailspin.h>

#include <stdbool.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <libproc.h>
#include <Foundation/NSTask.h>
#import <os/log.h>
#import <CoreTime/CoreTime.h>
#include <os/variant_private.h>
#import <SoftLinking/SoftLinking.h>
#if TARGET_OS_OSX
    #import <PackageKit/PackageKit.h>
    #import <DistributionKit/PKDistributionController.h>
#endif
#import <MobileGestalt.h>
#import <Security/SecTrustStore.h>
#import <OSAnalytics/OSASystemConfiguration_Public.h>

// For NSURLSessionTask._timeoutIntervalForResource
#import <CFNetwork/CFNSURLConnection.h>
#include <libaks.h>
#include <uuid/uuid.h>
#include <libaks_filevault.h>

extern bool shim_allows_internal_security_policies(void);
extern bool shim_WIFSIGNALED(int32_t status);
extern int shim_WTERMSIG(int32_t status);
extern bool shim_WIFEXITED(int32_t status);
extern int shim_WEXITSTATUS(int32_t status);
extern int shim_reboot3(uint64_t flag);
extern int shim_reboot3_with_purpose(uint64_t flag, rb3_userreboot_purpose_t_t purpose);
extern int64_t shim_MGQUniqueChipID(void);
extern NSString* shim_MGQSerialNumber(void);
extern NSNumber* shim_MGQOceanComputeCarrierID(void);
extern NSNumber* shim_MGQOceanComputeCarrierSlot(void);
extern int64_t shim_MGQChipID(void);
extern int64_t shim_MGQBoardID(void);
extern int64_t shim_MGQSecurityDomain(void);
extern uint8_t* shim_MGPROD_E126B(void);
extern uint8_t* shim_MGPROD_E126T(void);
extern uint8_t* shim_MGPROD_E130(void);
extern bool shim_TMSetupTime(void);
extern bool support_package_install(void);
extern int shim_register_config(NSData *data);
extern int shim_register_secureconfig_parameters(NSData *data, NSString *securityPolicy);
extern int shim_kIOReturnNoResources(void);
extern NSString* shim_automatedDeviceGroup(void);
extern void shim_setAutomatedDeviceGroup(NSString *automatedDeviceGroup);
errno_t shim_cryptex_lockdown(void);
bool shim_check_tailspin(void);
bool shim_validateImage4Ticket(const void * _Nonnull manifest, size_t manifest_len, const void * _Nonnull trustcache, size_t trustcache_len);
extern int aks_fv_set_protection(aks_fv_param_t params, aks_fv_prot_cmd_t cmd, aks_fv_prot_opts_t opts, const aks_fv_data_t secret, const aks_fv_data_t kek_blob, const aks_fv_data_t vek_blob, aks_fv_data_t vek_blob_out);

//rdar://130220223 (Change tailspin link to Weakling)
SOFT_LINK_DYLIB(libtailspin);
SOFT_LINK_FUNCTION(libtailspin, tailspin_config_create_with_default_config, shim_tailspin_config_create_with_default_config, tailspin_config_t, (void), ());
SOFT_LINK_FUNCTION(libtailspin, tailspin_config_create_new, shim_tailspin_config_create_new, tailspin_config_t, (void), ());
SOFT_LINK_FUNCTION(libtailspin, tailspin_full_sampling_period_set, shim_tailspin_full_sampling_period_set, void, (tailspin_config_t config, uint64_t full_sampling_period_ns), (config, full_sampling_period_ns));
SOFT_LINK_FUNCTION(libtailspin, tailspin_enabled_set, shim_tailspin_enabled_set, void, (tailspin_config_t config, bool tailspin_enabled),(config, tailspin_enabled));
SOFT_LINK_FUNCTION(libtailspin, tailspin_oncore_sampling_period_set, shim_tailspin_oncore_sampling_period_set, void, (tailspin_config_t config, uint64_t oncore_sampling_period_ns),(config, oncore_sampling_period_ns));
SOFT_LINK_FUNCTION(libtailspin, tailspin_buffer_size_set, shim_tailspin_buffer_size_set, void, (tailspin_config_t config, size_t buf_size_mb),(config, buf_size_mb));
SOFT_LINK_FUNCTION(libtailspin, tailspin_kdbg_filter_class_set, shim_tailspin_kdbg_filter_class_set, void, (tailspin_config_t config, uint8_t class_number, bool enabled),(config, class_number, enabled));
SOFT_LINK_FUNCTION(libtailspin, tailspin_kdbg_filter_subclass_set, shim_tailspin_kdbg_filter_subclass_set, void, (tailspin_config_t config, uint8_t class_number, uint8_t subclass_number, bool enabled),(config, class_number, subclass_number, enabled));
SOFT_LINK_FUNCTION(libtailspin, tailspin_enabled_get, shim_tailspin_enabled_get, bool, (const tailspin_config_t config),(config));
SOFT_LINK_FUNCTION(libtailspin, tailspin_buffer_size_get, shim_tailspin_buffer_size_get, size_t, (const tailspin_config_t config),(config));
SOFT_LINK_FUNCTION(libtailspin, tailspin_kdbg_filter_subclass_get, shim_tailspin_kdbg_filter_subclass_get, bool, (const tailspin_config_t config, uint8_t class_number, uint8_t subclass_number),(config, class_number, subclass_number));
SOFT_LINK_FUNCTION(libtailspin, tailspin_kdbg_filter_class_get_partial, shim_tailspin_kdbg_filter_class_get_partial, bool, (const tailspin_config_t config, uint8_t class_number), (config, class_number));
SOFT_LINK_FUNCTION(libtailspin, tailspin_kdbg_filter_class_get, shim_tailspin_kdbg_filter_class_get, bool, (const tailspin_config_t config, uint8_t class_number), (config, class_number));
SOFT_LINK_FUNCTION(libtailspin, tailspin_config_apply_sync, shim_tailspin_config_apply_sync, bool, (const tailspin_config_t config), (config));
SOFT_LINK_FUNCTION(libtailspin, tailspin_config_free, shim_tailspin_config_free, void, (tailspin_config_t config), (config));
