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
//  SecureConfigDB.m
//  SecureConfigDB
//

#import "SecureConfigDB.h"
#import "SecureConfigDB-Swift.h"
#import <os/log.h>
#import <CoreFoundation/CoreFoundation.h>

@interface SecureConfigParameters()
@property(readonly, nonatomic) _SecureConfigParameters *obj;
@end

@implementation SecureConfigParameters
- (instancetype) initWithUnderlyingObject:(_SecureConfigParameters *)obj
{
	if (self = [super init]) {
		_obj = obj;
	}
	return self;
}

+ (SecureConfigParameters * _Nullable)loadContentsAndReturnError:(NSError * _Nullable * _Nullable)error
{
	SecureConfigParameters *result = nil;
	_SecureConfigParameters *obj = nil;

	obj = [_SecureConfigParameters loadContentsAndReturnError:error];
	if (obj) {
		result = [[SecureConfigParameters alloc] initWithUnderlyingObject:obj];
	}

	return result;
}

- (CFBooleanRef)research_disableAppleInfrastructureEnforcement
{
	return self.obj.research_disableAppleInfrastructureEnforcement;
}

- (NSArray<NSString *> *)cryptexAppIdentifiers
{
	return self.obj.cryptexAppIdentifiers;
}

@end

secure_config_database_t _Nullable
secure_config_get_default_database(void) {
	return [[SCDataBase alloc] init];
}

secure_config_parameters_t
secure_config_parameters_load_with_error(CFErrorRef _Nullable *_Nullable outError) {
	NSError *error = nil;
	SecureConfigParameters *parameters = [SecureConfigParameters loadContentsAndReturnError:&error];
	if (outError) {
		*outError = (__bridge CFErrorRef)error;
	}
	return parameters;
}

CFArrayRef
secure_config_parameters_copy_cryptex_app_identifiers_4libcryptex(secure_config_parameters_t parameters) {
	// N.B. Do not send this object -copy
	// rdar://156916451 (Copying Bridged Swift Array Object Results in Invalid (CF) Object)
	CFArrayRef res = (__bridge CFArrayRef)[parameters cryptexAppIdentifiers];
	if (res) {
		CFRetain(res);
	}
	return res;
}

secure_config_slot_t
secure_config_database_create_slot(secure_config_database_t database,
	uuid_t _Nonnull slotID, ratcheting_algorithm_t algo,
	const char * record_type) {
		return secure_config_database_create_slot_with_saltdata(database, slotID, algo, record_type, NULL, 0);
	}

secure_config_slot_t
secure_config_database_create_slot_with_saltdata(secure_config_database_t database,
	uuid_t _Nonnull slotID, ratcheting_algorithm_t algo,
	const char * record_type, const uint8_t *_Nullable salt, size_t salt_len) {
	NSUUID *uuid = [[NSUUID alloc] initWithUUIDBytes:slotID];

	NSString *algoStr = nil;
	NSString *recordType = @(record_type);
	switch (algo) {
		case SCDB_ALGO_SHA256:
			algoStr = @"sha256";
			break;
		case SCDB_ALGO_SHA384:
			algoStr = @"sha384";
			break;
		default:
			os_log_error(OS_LOG_DEFAULT, "Unexpected algorithm");
			return nil;
			break;
	}
	if (salt) {
		NSData *saltData = [[NSData alloc] initWithBytes:salt length:salt_len];
		return [database slotWithSlotID:uuid algorithm:algoStr recordType:recordType salt:saltData error:nil];
	} else
		return [database slotWithSlotID:uuid algorithm:algoStr recordType:recordType salt:nil error:nil];
}

OS_OBJECT_RETURNS_RETAINED
secure_config_entry_t _Nullable
secure_config_entry_create_with_buffer(const char *buff, size_t buff_size) {
	if (buff == NULL || buff_size == 0) {
		return nil;
	}

	NSData* data = [NSData dataWithBytes:buff length:buff_size];
	if (!data) {
		return nil;
	}

	return [[SCEntry alloc] initWithData:data metadata:nil];
}

int
secure_config_entry_set_metadata(secure_config_entry_t entry,
		const char *key, const char *buff, size_t buff_size) {
	int32_t err = -1;
	if (entry && key && buff && buff_size > 0) {
		NSData* data = [NSData dataWithBytes:buff length:buff_size];
		if (data) {
			[entry setMetadataWithKey: @(key) data:data];
			err = 0;
		}
	}
	return err;
}

int
secure_config_slot_append_entry(secure_config_slot_t slot, secure_config_entry_t entry) {
	NSError *error = nil;
	bool result = [slot append:entry error:&error];

	if (!result) {
		os_log_error(OS_LOG_DEFAULT, "Failed to append to secure config slot: %tu %@",
				error.code, error.domain);
	}

	return !result;
}
