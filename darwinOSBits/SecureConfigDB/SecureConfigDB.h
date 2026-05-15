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
//  SecureConfigDB.h
//  SecureConfigDB
//

#ifndef __SECURECONFIGDB_H
#define __SECURECONFIGDB_H

#include <stdio.h>
#include <stdlib.h>
#include <CoreFoundation/CoreFoundation.h>

#if defined(__OBJC__) && __OBJC__
#include <Foundation/Foundation.h>
#endif // defined(__OBJC__) && __OBJC__

OS_ASSUME_NONNULL_BEGIN

#ifndef SECURECONFIG_OBJECT_EXPORT_DECL_WITH_C_TYPE
#if defined(__OBJC__) && __OBJC__
#define SECURECONFIG_OBJECT_EXPORT_DECL_WITH_C_TYPE(obj_class, c_type) \
		@class obj_class; \
		typedef obj_class *c_type;
#else
#define SECURECONFIG_OBJECT_EXPORT_DECL_WITH_C_TYPE(obj_class,c_type) \
		typedef struct OS_ ## obj_class *c_type;
#endif // defined(__OBJC__) && __OBJC__
#endif // ifndef CRYPTEX_OBJECT_EXPORT_DECL_WITH_C_TYPE

SECURECONFIG_OBJECT_EXPORT_DECL_WITH_C_TYPE(SCDataBase, secure_config_database_t);
SECURECONFIG_OBJECT_EXPORT_DECL_WITH_C_TYPE(SCSlot, secure_config_slot_t);
SECURECONFIG_OBJECT_EXPORT_DECL_WITH_C_TYPE(SCEntry, secure_config_entry_t);
SECURECONFIG_OBJECT_EXPORT_DECL_WITH_C_TYPE(SecureConfigParameters, secure_config_parameters_t);

#if defined(__OBJC__) && __OBJC__
@interface SecureConfigParameters : NSObject
@property (nonatomic, readonly) CFBooleanRef _Nullable research_disableAppleInfrastructureEnforcement;
+ (SecureConfigParameters * _Nullable)loadContentsAndReturnError:(NSError * _Nullable * _Nullable) error NS_WARN_UNUSED_RESULT;
@end
#endif // defined(__OBJC__) && __OBJC__

/*!
 * @function secure_config_parameters_load_with_error
 * Loads the secure config parameters and creates an object representing its contents.
 *
 * @param outError
 * An error returned if loading or decoding the value of the secure config parameters fails.
 *
 * @result
 * Returns a `secure_config_parameters_t` if loading and decoding the secure
 * config parameters was successful. If either operation fails, the result is `nil`, and
 * the `ourError` parameter will be populated with an error value.
 */
secure_config_parameters_t _Nullable
secure_config_parameters_load_with_error(CFErrorRef _Nullable *_Nullable outError);

/*!
 * @function secure_config_parameters_copy_cryptex_app_identifiers_4libcryptex
 * Copies the value of the "com.apple.libcryptex.appIdentifiers" key from the secure
 * config parameters.
 *
 * WARNING: This function is SPI that exists for libcryptex. Talk to the SecureConfigDB
 * team if you want to consume it outside of that context.
 *
 * @param parameters
 * An instance of the loaded secure config parameters.
 *
 * @returns
 * A copy of the value of the "com.apple.libcryptex.appIdentifiers" key from the secure
 * config parameters, or `nil` if no such value exists. It is the responsibility of the
 * caller to release this copied value.
 */
CF_RETURNS_RETAINED
CFArrayRef _Nullable
secure_config_parameters_copy_cryptex_app_identifiers_4libcryptex(secure_config_parameters_t parameters);

OS_ENUM(ratcheting_algorithm, uint32_t,
	SCDB_ALGO_UNK = 0,
	SCDB_ALGO_SHA256,
	SCDB_ALGO_SHA384,
);

OS_OBJECT_RETURNS_RETAINED
secure_config_database_t _Nullable
secure_config_get_default_database(void);

/*!
 * @function secure_config_database_create_slot
 * Creates a slot object representing the given slot ID with the provided parameters.
 *
 * If this slot has not yet been created in the database, it will be created. If it has been
 * created previously, the provided algorithm and record type will be validated against
 * the previously values and if they match a reference to the existing slot will be returned.
 *
 * @param slotID
 * The SEP slot used to ratchet the entries
 *
 * @param algo
 * Enum representation of the algorithm. Current expected values are sha256
 * and sha384.
 *
 * @param record_type
 * String representing the record type. Expected "cryptex" but can be anything
 *
 * @result
 * Returns a ratcheted_entry_slot_t if successful. If the algorithm or record_type
 * do not match the previous times the slot was created, nil will be returned. If the
 * algorithm is the default RE_ALGO_UNK it will return nil.
 */

OS_OBJECT_RETURNS_RETAINED
secure_config_slot_t
secure_config_database_create_slot(secure_config_database_t database,
	uuid_t _Nonnull slotID, ratcheting_algorithm_t algo,
	const char * record_type);


/*!
 * @function secure_config_database_create_slot_with_saltdata
 * Replicates the behavior of secure_config_database_create_slot with the option
 * to include a salt as an additional parameter in the slot.
 * 
 * @param slotID
 * The SEP slot used to ratchet the entries
 *
 * @param algo
 * Enum representation of the algorithm. Current expected values are sha256
 * and sha384.
 *
 * @param record_type
 * String representing the record type. Expected "cryptex" but can be anything
 * 
 * @param salt
 * Salt used to seal the slotID hash.
 *
 * @param salt_len
 * The length in bytes of the salt byte array.
 *
 * @result
 * Returns a ratcheted_entry_slot_t if successful. If the algorithm or record_type
 * do not match the previous times the slot was created, nil will be returned. If the
 * algorithm is the default RE_ALGO_UNK it will return nil.
 */
OS_OBJECT_RETURNS_RETAINED
secure_config_slot_t
secure_config_database_create_slot_with_saltdata(secure_config_database_t database,
	uuid_t _Nonnull slotID, ratcheting_algorithm_t algo,
	const char * record_type, const uint8_t *_Nullable salt, size_t salt_len);

/*!
 * @function secure_config_entry_create_with_buffer
 * Creates a new secure_config_entry_t object with  the contetns described in the buffer.  Use
 * secure_config_entry_set_metadata as many times as necessary to add individual metadata
 *
 * @param buff
 * A pointer to the raw bytes containing the metadata.
 *
 * @param buff_size
 * Size of the data contained in buff
 *
 * @result
 * Returns the secure_config_entry_t object to populate the additional information.
 */
OS_OBJECT_RETURNS_RETAINED
secure_config_entry_t _Nullable
secure_config_entry_create_with_buffer(const char *buff, size_t buff_size);

/*!
 * @function secure_config_entry_set_metadata
 * This function is used to provide additional optional metadata to the
 * secure config entry. When the consumer requests a summary of the contents at
 * slot ID, the entry will be accompanied with this metadata.
 *
 * @param entry
 * Object representing the contents that were passed in to the ask_sealed_hash
 * call.
 *
 * @param key
 * String key identifying this metadata in the event that the entry has
 * multiple metadata values. These key names are defined in a slot-specific
 * way.
 *
 * @param buff
 * A pointer to the raw bytes containing the metadata.
 *
 * @param buff_size
 * Size of the data contained in buff
 *
 * @result
 * Will return 0 upon SUCCESS or the respective @link errno.  The implementation
 * may directly return any of the following error codes:
 *  [TBD]
 */
int
secure_config_entry_set_metadata(secure_config_entry_t entry,
		const char *key, const char *buff, size_t buff_size);

/*!
 * @function secure_config_slot_append_entry
 * A method to register a general entry into secureconfig data store. This entry
 * will be added to the ordered list of entries that were ratcheted in the slot.
 * For the sealed hash to match what is in the SEP, it is necessary that the
 * digest that is passed in digest_ptr exactly match the contents that were
 * already passed in to the aks_sealed_hash call.
 *
 * @param entry
 * Object representing the contents that were passed in to the ask_sealed_hash
 * call.
 *
 * @result
 * Will return 0 upon success or non-zero on error
 */
int
secure_config_slot_append_entry(secure_config_slot_t slot, secure_config_entry_t entry);

OS_ASSUME_NONNULL_END

#endif // __SECURECONFIGDB_H
