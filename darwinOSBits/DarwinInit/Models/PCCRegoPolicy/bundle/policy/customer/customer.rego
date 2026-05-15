# Copyright © 2025 Apple Inc. All Rights Reserved.

# APPLE INC.
# PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT
# PLEASE READ THE FOLLOWING PRIVATE CLOUD COMPUTE SOURCE CODE INTERNAL USE LICENSE AGREEMENT (“AGREEMENT”) CAREFULLY BEFORE DOWNLOADING OR USING THE APPLE SOFTWARE ACCOMPANYING THIS AGREEMENT(AS DEFINED BELOW). BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING TO BE BOUND BY THE TERMS OF THIS AGREEMENT. IF YOU DO NOT AGREE TO THE TERMS OF THIS AGREEMENT, DO NOT DOWNLOAD OR USE THE APPLE SOFTWARE. THESE TERMS AND CONDITIONS CONSTITUTE A LEGAL AGREEMENT BETWEEN YOU AND APPLE.
# IMPORTANT NOTE: BY DOWNLOADING OR USING THE APPLE SOFTWARE, YOU ARE AGREEING ON YOUR OWN BEHALF AND/OR ON BEHALF OF YOUR COMPANY OR ORGANIZATION TO THE TERMS OF THIS AGREEMENT.
# 1. As used in this Agreement, the term “Apple Software” collectively means and includes all of the Apple Private Cloud Compute materials provided by Apple here, including but not limited to the Apple Private Cloud Compute software, tools, data, files, frameworks, libraries, documentation, logs and other Apple-created materials. In consideration for your agreement to abide by the following terms, conditioned upon your compliance with these terms and subject to these terms, Apple grants you, for a period of ninety (90) days from the date you download the Apple Software, a limited, non-exclusive, non-sublicensable license under Apple’s copyrights in the Apple Software to download, install, compile and run the Apple Software internally within your organization only on a single Apple-branded computer you own or control, for the sole purpose of verifying the security and privacy characteristics of Apple Private Cloud Compute. This Agreement does not allow the Apple Software to exist on more than one Apple-branded computer at a time, and you may not distribute or make the Apple Software available over a network where it could be used by multiple devices at the same time. You may not, directly or indirectly, redistribute the Apple Software or any portions thereof. The Apple Software is only licensed and intended for use as expressly stated above and may not be used for other purposes or in other contexts without Apple's prior written permission. Except as expressly stated in this notice, no other rights or licenses, express or implied, are granted by Apple herein.
# 2. The Apple Software is provided by Apple on an "AS IS" basis. APPLE MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS, SYSTEMS, OR SERVICES. APPLE DOES NOT WARRANT THAT THE APPLE SOFTWARE WILL MEET YOUR REQUIREMENTS, THAT THE OPERATION OF THE APPLE SOFTWARE WILL BE UNINTERRUPTED OR ERROR-FREE, THAT DEFECTS IN THE APPLE SOFTWARE WILL BE CORRECTED, OR THAT THE APPLE SOFTWARE WILL BE COMPATIBLE WITH FUTURE APPLE PRODUCTS, SOFTWARE OR SERVICES. NO ORAL OR WRITTEN INFORMATION OR ADVICE GIVEN BY APPLE OR AN APPLE AUTHORIZED REPRESENTATIVE WILL CREATE A WARRANTY.
# 3. IN NO EVENT SHALL APPLE BE LIABLE FOR ANY DIRECT, SPECIAL, INDIRECT, INCIDENTAL OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION, COMPILATION OR OPERATION OF THE APPLE SOFTWARE, HOWEVER CAUSED AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE), STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
# 4. This Agreement is effective until terminated. Your rights under this Agreement will terminate automatically without notice from Apple if you fail to comply with any term(s) of this Agreement. Upon termination, you agree to cease all use of the Apple Software and destroy all copies, full or partial, of the Apple Software. This Agreement constitutes the entire understanding of the parties with respect to the subject matter contained herein, and supersedes all prior negotiations, representations, or understandings, written or oral. This Agreement will be governed and construed in accordance with the laws of the State of California, without regard to its choice of law rules.
# You may report security issues about Apple products to product-security@apple.com, as described here: https://www.apple.com/support/security/. Non-security bugs and enhancement requests can be made via https://bugreport.apple.com as described here: https://developer.apple.com/bug-reporting/
# EA1937
# 10/02/2024

package policy.customer

import rego.v1

import data.policy.common.has_key

# METADATA
# title: deny if ssh.enabled is set to true
# custom:
#  version: 8
#  key: ssh.enabled
deny contains issue if {
	config := input["darwin-init"][i]
	config.ssh.enabled == true
	msg := sprintf("Enabling ssh daemon not permitted. %s must be unset or false", [rego.metadata.rule().custom.key])

	version := rego.metadata.rule().custom.version
	issue := {
		"index": i,
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if ssh password authentication is enabled
# custom:
#  version: 8
#  key: ssh.pwauth
deny contains issue if {
	config := input["darwin-init"][i]
	config.ssh.pwauth == true
	msg := sprintf("Enabling ssh password authentication not permitted. %s must be unset or false", [rego.metadata.rule().custom.key])

	version := rego.metadata.rule().custom.version
	issue := {
		"index": i,
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if log.privacy_level is not set to Public in config 0
# custom:
#  version: 8
#  key: log.privacy_level
deny contains issue if {
	i = 0
	config := input["darwin-init"][i]
	not config.log.privacy_level == "Public"
	msg := sprintf("Private logs must be redacted by setting %s to Public", [rego.metadata.rule().custom.key])

	issue := {
		"index": i,
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if log.privacy_level is present in configs at index i > 0
# custom:
#  version: 8
#  key: log.privacy_level
deny contains issue if {
	i > 0
	config := input["darwin-init"][i]
	has_key(config.log, "privacy_level")
	msg := sprintf("%s may only be set in config 0", [rego.metadata.rule().custom.key])

	issue := {
		"index": i,
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if log.persist is not set to false in config 0
# custom:
#  version: 8
#  key: log.persist
deny contains issue if {
	i = 0
	config := input["darwin-init"][i]
	not config.log.persist == false
	msg := sprintf("Logging to disk and snapshots must be disabled by setting %s to false", [rego.metadata.rule().custom.key])

	issue := {
		"index": i,
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if log.persist is present in configs at index i > 0
# custom:
#  version: 8
#  key: log.persist
deny contains issue if {
	i > 0
	config := input["darwin-init"][i]
	has_key(config.log, "persist")
	msg := sprintf("%s may only be set in config 0", [rego.metadata.rule().custom.key])

	issue := {
		"index": i,
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if finish.userspace_reboot not set to "rem" (unset also acceptable) in config 0
# custom:
#  version: 8
#  key: finish.userspace_reboot
deny contains issue if {
	i = 0
	config := input["darwin-init"][i]
	has_key(config.finish, "userspace_reboot")
	not config.finish.userspace_reboot == "rem"
	msg := sprintf("Opting out of userspace reboot into rem not permitted. %s must be unset or set to \"rem\"", [rego.metadata.rule().custom.key])

	issue := {
		"index": i,
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if finish.userspace_reboot present in configs at index i > 0
# custom:
#  version: 8
#  key: finish.userspace_reboot
deny contains issue if {
	i > 0
	config := input["darwin-init"][i]
	has_key(config.finish, "userspace_reboot")
	msg := sprintf("%s may only be set in config 0", [rego.metadata.rule().custom.key])

	issue := {
		"index": i,
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# Gather all secure_config entries across array as entries with form {"key": key, "value": value, "source": i}
all_entries := [entry |
	some i
	config := input["darwin-init"][i]
	some key, value in config.secure_config
	entry := {"key": key, "value": value, "source": i}
]

# Group secure_config entries by key
entries_by_key := {key: key_entries |
	key := {entry.key | entry := all_entries[_]}[_]
	key_entries := [entry |
		entry := all_entries[_]
		entry.key == key
	]
}

# METADATA
# title: deny if secure_config settings conflict within array
# custom:
#  key: secure_config
#  version: 8
deny contains issue if {
	some key
	entries := entries_by_key[key]
	values := {entry.value | entry := entries[_]}
	count(values) > 1
	indices := [source |
		entry := entries[_]
		source := entry.source
	]
	msg := sprintf("Conflicting settings for secure_config param %s in configs %v", [key, indices])

	# Report conflict at each involved index
	some idx in indices
	issue := {
		"index": idx,
		"key": sprintf("secure_config.%s", [key]),
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# Merge secure_config settings, ommitting keys with conflicting values
net_secure_config := {key: value |
	key := object.keys(entries_by_key)[_]
	entries := entries_by_key[key]
	count({entry.value | entry := entries[_]}) == 1 # No conflicts
	value := entries[0].value
}

# METADATA
# title: deny if secure_config.com.apple.logging.crashRedactionEnabled not true
# custom:
#  key: secure_config.com.apple.logging.crashRedactionEnabled
#  version: 8
deny contains issue if {
	not net_secure_config["com.apple.logging.crashRedactionEnabled"] == true
	msg := sprintf("%s must be set to true", [rego.metadata.rule().custom.key])

	issue := {
		"index": 0, # Report at index 0 for merged config validation
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if secure_config.com.apple.tie.internalRequestOptionsAllowed is true
# custom:
#  key: secure_config.com.apple.tie.internalRequestOptionsAllowed
#  version: 8
deny contains issue if {
	net_secure_config["com.apple.tie.internalRequestOptionsAllowed"] == true
	msg := sprintf("%s must be unset or false", [rego.metadata.rule().custom.key])

	issue := {
		"index": 0, # Report at index 0 for merged config validation
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if secure_config.com.apple.tie.allowNonProdExceptionOptions is true
# custom:
#  key: secure_config.com.apple.tie.allowNonProdExceptionOptions
#  version: 8
deny contains issue if {
	net_secure_config["com.apple.tie.allowNonProdExceptionOptions"] == true
	msg := sprintf("%s must be unset or false", [rego.metadata.rule().custom.key])

	issue := {
		"index": 0, # Report at index 0 for merged config validation
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if secure_config.com.apple.logging.logFilteringEnforced not true
# custom:
#  key: secure_config.com.apple.logging.logFilteringEnforced
#  version: 8
deny contains issue if {
	not net_secure_config["com.apple.logging.logFilteringEnforced"] == true
	msg := sprintf("%s must be set to true", [rego.metadata.rule().custom.key])

	issue := {
		"index": 0, # Report at index 0 for merged config validation
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if secure_config.com.apple.logging.policyPath is missing
# custom:
#  key: secure_config.com.apple.logging.policyPath
#  version: 8
deny contains issue if {
	customer_path := "/private/var/PrivateCloudSupport/opt/audit-lists/customer/"
	not has_key(net_secure_config, "com.apple.logging.policyPath")
	msg := sprintf("%s must be set to %s", [rego.metadata.rule().custom.key, customer_path])

	issue := {
		"index": 0, # Report at index 0 for merged config validation
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if secure_config.com.apple.logging.policyPath not set to "/private/var/PrivateCloudSupport/opt/audit-lists/customer/"
# custom:
#  key: secure_config.com.apple.logging.policyPath
#  version: 8
deny contains issue if {
	customer_path := "/private/var/PrivateCloudSupport/opt/audit-lists/customer/"
	policy_path := net_secure_config["com.apple.logging.policyPath"]
	has_key(net_secure_config, "com.apple.logging.policyPath")
	not policy_path == customer_path
	msg := sprintf("%s must be set to %s", [rego.metadata.rule().custom.key, customer_path])

	issue := {
		"index": 0, # Report at index 0 for merged config validation
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if secure_config.com.apple.logging.metricsFilteringEnforced not true
# custom:
#  key: secure_config.com.apple.logging.metricsFilteringEnforced
#  version: 8
deny contains issue if {
	not net_secure_config["com.apple.logging.metricsFilteringEnforced"] == true
	msg := sprintf("%s must be set to true", [rego.metadata.rule().custom.key])

	issue := {
		"index": 0, # Report at index 0 for merged config validation
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if secure_config.com.apple.pcc.research.disableAppleInfrastrucutureEnforcement true on bare metal
# custom:
#  key: secure_config.com.apple.pcc.research.disableAppleInfrastrucutureEnforcement
#  version: 8
deny contains issue if {
	not input.meta.is_vm == true
	net_secure_config["com.apple.pcc.research.disableAppleInfrastrucutureEnforcement"] == true
	msg := sprintf("%s must be set to false unless in a vm", [rego.metadata.rule().custom.key])

	issue := {
		"index": 0, # Report at index 0 for merged config validation
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if secure_config.com.apple.cloudboard.isProxy is true
# custom:
#  key: secure_config.com.apple.cloudboard.isProxy
#  version: 8
deny contains issue if {
	net_secure_config["com.apple.cloudboard.isProxy"] == true
	msg := sprintf("%s must be false or unset", [rego.metadata.rule().custom.key])

	issue := {
		"index": 0, # Report at index 0 for merged config validation
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if secure_config.com.apple.libcryptex.appIdentifiers are invalid - must consist of alphanumeric characters, periods, and hyphens
# custom:
#  key: secure_config.com.apple.libcryptex.appIdentifiers
#  version: 11
deny contains issue if {
	app_ids = net_secure_config["com.apple.libcryptex.appIdentifiers"]
	valid_chars := "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-."
	some app_id in app_ids
	chars := split(app_id, "")
	some char in chars
	not contains(valid_chars, char)
	msg := sprintf("%s must consist of alphanumeric characters, periods, and hyphens. \"%s\" is invalid", [rego.metadata.rule().custom.key, app_id])

	issue := {
		"index": 0, # Report at index 0 for merged config validation
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if secure_config.com.apple.libcryptex.appIdentifiers are invalid - must be non-empty
# custom:
#  key: secure_config.com.apple.libcryptex.appIdentifiers
#  version: 11
deny contains issue if {
	app_ids = net_secure_config["com.apple.libcryptex.appIdentifiers"]
	some app_id in app_ids
	app_id == ""
	msg := sprintf("%s must be non-empty strings. \"%s\" is invalid", [rego.metadata.rule().custom.key, app_id])

	issue := {
		"index": 0, # Report at index 0 for merged config validation
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if cfpref is not in allowlist
# description: PrivateCloudOSValidator (darwinOSBits)
# custom:
#  key: preferences
#  version: 8
deny contains issue if {
	allowed_application_ids := {
		"com.apple.acdc.cloudmetricsd",
		"com.apple.acsi.cloudusagetrackingd",
		"com.apple.cloudos",
		"com.apple.cloudos.AppleComputeEnsembler",
		"com.apple.cloudos.cb_attestationd",
		"com.apple.cloudos.cb_configurationd",
		"com.apple.cloudos.cb_jobauthd",
		"com.apple.cloudos.cb_jobhelper",
		"com.apple.cloudos.cloudOSInfo",
		"com.apple.cloudos.cloudboardd",
		"com.apple.cloudos.CloudBoardNullApp",
		"com.apple.cloudos.NullCloudController",
		"com.apple.cloudos.hotproperties.cb_attestationd",
		"com.apple.cloudos.hotproperties.cb_jobhelper",
		"com.apple.cloudos.hotproperties.cloudboardd",
		"com.apple.cloudos.hotproperties.splunkloggingd",
		"com.apple.cloudos.hotproperties.test",
		"com.apple.cloudos.hotproperties.tie",
		"com.apple.prcos.splunkloggingd",
		"com.apple.privateCloudCompute",
		"com.apple.thimble.inference.tie-controllerd",
	}
	config := input["darwin-init"][i]
	prefs := config.preferences
	some user in prefs
	some app_id, _ in user
	not app_id in allowed_application_ids
	msg := sprintf("%s not allowed. Setting CFPrefs only permitted for the following application IDs: %s", [app_id, allowed_application_ids])

	issue := {
		"index": i,
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if cfpref key for com.apple.thimble.inference.tie-controllerd is not in allowlist
# description: PrivateCloudOSValidator (darwinOSBits)
# custom:
#  key: preferences
#  version: 9
deny contains issue if {
	config := input["darwin-init"][i]
	allowed_keys := {"RoutingLayerFormat", "RoutingGroupAliases"}
	prefs := config.preferences
	some user, pref in prefs
	some app_id, kv in pref
	app_id == "com.apple.thimble.inference.tie-controllerd"
	some key, _ in kv
	not key in allowed_keys
	msg := sprintf("%s not allowed. Only the following CFPrefs keys may be set under application ID %s: %s", [key, app_id, allowed_keys])

	issue := {
		"index": i,
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if darwin-init.roots is present
# description: PrivateCloudOSValidator (darwinOSBits)
# custom:
#  version: 8
#  key: roots
deny contains issue if {
	config := input["darwin-init"][i]
	has_key(config, "roots")
	msg := sprintf("Installing custom roots not permitted. %s must be unset", [rego.metadata.rule().custom.key])

	issue := {
		"index": i,
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if darwin-init.diavlo is present
# description: PrivateCloudOSValidator (darwinOSBits)
# custom:
#  version: 8
#  key: diavlo
deny contains issue if {
	config := input["darwin-init"][i]
	has_key(config, "diavlo")
	msg := sprintf("Diavlo personalization of cryptexes not supported. %s must be unset", [rego.metadata.rule().custom.key])

	issue := {
		"index": i,
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if darwin-init.package is present
# description: PrivateCloudOSValidator (darwinOSBits)
# custom:
#  version: 8
#  key: packages
deny contains issue if {
	config := input["darwin-init"][i]
	has_key(config, "packages")
	msg := sprintf("Installing packages not permitted. %s must be unset", [rego.metadata.rule().custom.key])

	issue := {
		"index": i,
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if darwin-init.user is present
# description: PrivateCloudOSValidator (darwinOSBits)
# custom:
#  version: 8
#  key: users
deny contains issue if {
	config := input["darwin-init"][i]
	has_key(config, "users")
	msg := sprintf("Creating and configuring users not permitted. %s must be unset", [rego.metadata.rule().custom.key])

	issue := {
		"index": i,
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if darwin-init.network.interfaces is present
# description: PrivateCloudOSValidator (darwinOSBits)
# custom:
#  version: 8
#  key: network.interfaces
deny contains issue if {
	config := input["darwin-init"][i]
	has_key(config.network, "interfaces")
	msg := sprintf("Applying custom network configuration not permitted. %s must be unset", [rego.metadata.rule().custom.key])

	issue := {
		"index": i,
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if darwin-init.tailspin is present
# description: PrivateCloudOSValidator (darwinOSBits)
# custom:
#  version: 8
#  key: tailspin
deny contains issue if {
	config := input["darwin-init"][i]
	has_key(config, "tailspin")
	msg := sprintf("Applying custom tailspin configuration is not permitted. %s must be unset", [rego.metadata.rule().custom.key])

	issue := {
		"index": i,
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if darwin-init.finish.on_failure not set to reboot nor exit
# description: PrivateCloudOSValidator (darwinOSBits)
# custom:
#  version: 8
#  key: finish.on_failure
deny contains issue if {
	allowed_actions = {"reboot", "exit"}
	config := input["darwin-init"][i]
	action := config.finish.on_failure
	not action in allowed_actions
	msg := sprintf("%s must be set to reboot or exit", [rego.metadata.rule().custom.key])

	issue := {
		"index": i,
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if darwin-init.finish.reboot is set true
# description: PrivateCloudOSValidator (darwinOSBits)
# custom:
#  version: 8
#  key: finish.reboot
deny contains issue if {
	config := input["darwin-init"][i]
	config.finish.reboot == true
	msg := sprintf("System reboot after set up not permitted. %s must be unset or false", [rego.metadata.rule().custom.key])

	issue := {
		"index": i,
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if darwin-init.finish.scripts is present
# description: PrivateCloudOSValidator (darwinOSBits)
# custom:
#  version: 8
#  key: finish.scripts
deny contains issue if {
	config := input["darwin-init"][i]
	has_key(config.finish, "scripts")
	msg := sprintf("Executing scripts not permitted. %s must be unset", [rego.metadata.rule().custom.key])

	issue := {
		"index": i,
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if darwin-init.cryptex.lock is set false
# description: PrivateCloudOSValidator (darwinOSBits)
# custom:
#  version: 8
#  key: cryptex.lock
deny contains issue if {
	config := input["darwin-init"][i]
	config.cryptex.lock == false
	msg := sprintf("Disabling cryptex lockdown not permitted. %s must be unset or true", [rego.metadata.rule().custom.key])

	issue := {
		"index": i,
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if darwin-init.start.scripts is present
# description: PrivateCloudOSValidator (darwinOSBits)
# custom:
#  version: 8
#  key: start.scripts
deny contains issue if {
	config := input["darwin-init"][i]
	has_key(config.start, "scripts")
	msg := sprintf("Executing pre-init scripts not permitted. %s must be unset", [rego.metadata.rule().custom.key])

	issue := {
		"index": i,
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if darwin-init.cryptex.cache.retain_previously_cached_cryptexes_unsafely is true
# description: PrivateCloudOSValidator (darwinOSBits)
# custom:
#  version: 8
#  key: cryptex.cache.retain_previously_cached_cryptexes_unsafely
deny contains issue if {
	config := input["darwin-init"][i]
	config.cryptex.cache.retain_previously_cached_cryptexes_unsafely == true

	msg := sprintf("Retaining cryptexes from previous boot session configs not permitted. %s must be unset or false", [rego.metadata.rule().custom.key])

	issue := {
		"index": i,
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if darwin-init.cryptex.cache.cache_max_size is present
# description: PrivateCloudOSValidator (darwinOSBits)
# custom:
#  version: 8
#  key: cryptex.cache.cache_max_size
deny contains issue if {
	config := input["darwin-init"][i]
	has_key(config.cryptex.cache, "cache_max_size")
	msg := sprintf("Setting maximum storage space for cryptex cache not permitted. %s must be unset", [rego.metadata.rule().custom.key])

	issue := {
		"index": i,
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if darwin-init.anayltics.submit is true
# description: Prevent the customer from enabling diagnostic log submissions
# custom:
#  version: 8
#  key: analytics.submit
deny contains issue if {
	config := input["darwin-init"][i]
	config.analytics.submit == true

	msg := sprintf("Enabling diagnostic log submission not permitted. %s must be unset or false", [rego.metadata.rule().custom.key])

	issue := {
		"index": i,
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}

# METADATA
# title: deny if darwin-init.volumes is present
# description: PrivateCloudOSValidator (darwinOSBits)
# custom:
#  version: 10
#  key: volumes
deny contains issue if {
	config := input["darwin-init"][i]
	has_key(config, "volumes")
	msg := sprintf("Creating cache volumes not permitted. %s must be unset", [rego.metadata.rule().custom.key])

	issue := {
		"index": i,
		"key": rego.metadata.rule().custom.key,
		"message": msg,
		"version": rego.metadata.rule().custom.version,
	}
}
