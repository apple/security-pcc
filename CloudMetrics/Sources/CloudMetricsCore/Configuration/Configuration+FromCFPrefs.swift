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
//  Configuration+FromCFPrefs.swift
//  CloudMetrics
//
//  Created by Oliver Chick (ORAC) on 13/12/2024.
//

internal import CloudMetricsConstants
internal import CloudMetricsXPC
import Foundation
internal import os

extension Configuration {

    private static func destinationsFromMetricDestinationsCFPrefs() throws -> [String: Configuration.Destination]? {
        var metricDestinationsPref: [String : NSDictionary] = [:]

        /// Check for metric destinations in the cloudmetrics main CFPref domain
        if let metricDestinations = try preferencesDictOfDict("MetricDestinations") {
            metricDestinationsPref = metricDestinations
            logger.log("Loaded MetricDestinations from CloudMetrics domain. Destinations=\(metricDestinations, privacy: .public)")
        } else {
            return nil
        }

        /// Get metric destinations from its own CFPrefs domain, these take priority.
        if let metricDestinations = try allDictPreferencesIn(
            domain: kCloudMetricsPreferenceDomain + ".MetricDestinations"
        ) {
            for (workspace, destination) in metricDestinations {
                metricDestinationsPref[workspace] = destination
            }
            logger.log("Loaded MetricDestinations from its own domain. Destinations=\(metricDestinations, privacy: .public)")
        }

        guard metricDestinationsPref.count > 0 else {
            logger.error("Unable to get MetricDestinations from CFPrefs")
            return nil
        }

        logger.log("Merged MetricDestinations. Destinations=\(metricDestinationsPref, privacy: .public)")

        var destinations = [String: Configuration.Destination]()
        for (workspace, dest) in metricDestinationsPref {
            guard let publishInterval = dest["PublishInterval"] as? Int,
                  let namespace = dest["Namespace"] as? String,
                  let clients = dest["Clients"] as? [String]
            else {
                logger.error("Error decoding a MetricDestination from Preferences")
                throw ConfigurationError.invalidDestination(dest.description)
            }

            let configdest = Configuration.Destination(
                publishInterval: .seconds(publishInterval),
                workspace: workspace,
                namespace: namespace,
                clients: clients
            )
            destinations[workspace] = configdest
        }
        return destinations
    }

    private static func destinationsFromDestinationsCFPrefs() throws -> [Configuration.Destination] {
        guard let destinationsPref = try preferencesArrayOfDict("Destinations") else {
            logger.error("Error reading destinations from Preferences")
            throw ConfigurationError.noDestinations
        }
        var destinations = [Configuration.Destination]()
        for dest in destinationsPref {
            guard let publishInterval = dest["PublishInterval"] as? Int,
                  let workspace = dest["Workspace"] as? String,
                  let namespace = dest["Namespace"] as? String,
                  let clients = dest["Clients"] as? [String]
            else {
                logger.error("Error decoding a destination from Preferences")
                throw ConfigurationError.invalidDestination(dest.description)
            }

            let configdest = Configuration.Destination(
                publishInterval: .seconds(publishInterval),
                workspace: workspace,
                namespace: namespace,
                clients: clients
            )
            destinations.append(configdest)
        }
        return destinations
    }

    private static func openTelemetryEndpointFromCFPrefs() throws -> Configuration.OpenTelemetryEndpoint {
        guard let openTelemtryEndpoint = try preferencesDictionaryValue("OpenTelemetryEndpoint") else {
            return .init(hostname: "localhost", port: 4_317, mtls: false)
        }
        guard let hostname = openTelemtryEndpoint["Hostname"] as? String,
              let port = openTelemtryEndpoint["Port"] as? Int,
              let disableMTLS = openTelemtryEndpoint["DisableMtls"] as? Bool else {
            logger.error("Error decoding OpenTelemetryEndpoint from Preferences")
            throw ConfigurationError.invalidOpenTelemetryEndpoint(openTelemtryEndpoint.description)
        }
        return .init(hostname: hostname, port: port, mtls: !disableMTLS)
    }

    private static func auditListsFromCFPrefs() throws -> Configuration.AuditLists? {
        guard let auditLists = try preferencesDictionaryValue("AuditLists") else {
            return nil
        }
        guard let allowedMetrics = auditLists["AllowedMetrics"] as? [NSDictionary] else {
            throw ConfigurationError.auditListDecodingError

        }
        let metricRules = try allowedMetrics.map { ruleDict in
            let label: String = checkAndConvert(dict: ruleDict, key: "Label", defaultValue: "")
            let minUpdateInterval: Double = checkAndConvert(dict: ruleDict, key: "MinUpdateInterval", defaultValue: 0)
            let minPublishInterval: Double = checkAndConvert(dict: ruleDict, key: "MinPublishInterval", defaultValue: 0)
            let type: String? = checkAndConvert(dict: ruleDict, key: "Type", defaultValue: nil)
            let destinations: [String] = checkAndConvert(dict: ruleDict, key: "Destinations", defaultValue: [])
            let client: String = checkAndConvert(dict: ruleDict, key: "Client", defaultValue: "")
            let dimensions: [String: [String]] = checkAndConvert(dict: ruleDict, key: "Dimensions", defaultValue: [:])
            let metricType: CloudMetricType
            if let type {
                guard let type = CloudMetricType(rawValue: type) else {
                    logger.error("metric type invalid \(type, privacy: .public)")
                    throw ConfigurationError.unkownCloudMetricsType(type)
                }
                metricType = type
            } else {
                metricType = .all
            }

            let rulePlist = try Configuration.FilterRule(
                client: client,
                label: label,
                minUpdateInterval: .seconds(minUpdateInterval),
                minPublishInterval: .seconds(minPublishInterval),
                type: metricType,
                destinations: destinations.map({ try Configuration.Destination(id: $0) }),
                dimensions: dimensions)
            return rulePlist
        }
        var ignoredMetrics: [String: [String]] = [:]
        if let configuredIgnoredMetrics = auditLists["IgnoredMetrics"] as? [String: [String]] {
            ignoredMetrics = configuredIgnoredMetrics
        }
        return .init(allowedMetrics: metricRules, ignoredMetrics: ignoredMetrics)
    }

    private static func keySourceFromCFPrefs() throws -> Configuration.KeySource {
        guard let localCertificateConfig: [String: String] = try preferencesDictionaryValue("LocalCertificateConfig") else {
            return .keychain
        }
        let config = ConfigPlistCertificateConfig(mtlsPrivateKeyData: localCertificateConfig["MtlsPrivateKeyData"],
                                                  mtlsCertificateChainData: localCertificateConfig["MtlsCertificateChainData"])
        return .init(localCertificateConfig: config)
    }

    private static func destinationsFromCFPrefs() throws -> [Destination] {
        let metricDestinations = try Self.destinationsFromMetricDestinationsCFPrefs()
        if let metricDestinations, metricDestinations.count > 0 {
            return Array(metricDestinations.values)
        }
        return try Self.destinationsFromDestinationsCFPrefs()
    }

    private static func defaultDestinationFromCFPrefs() throws -> Destination {
        if let defaultDestinationPref = try preferencesDictionaryValue("DefaultDestination") {
            guard let defworkspace = defaultDestinationPref["Workspace"] as? String,
                  let defnamespace = defaultDestinationPref["Namespace"] as? String
            else {
                logger.error("Error decoding defaultDestination from Preferences")
                throw ConfigurationError.invalidDestination(defaultDestinationPref.description)
            }
            return .init(workspace: defworkspace, namespace: defnamespace)
        } else {
            logger.error("No defaultDestination found in Preferences")
            return.init(workspace: "", namespace: "")
        }
    }

    internal static func makeFromCFPrefs(auditLists: Configuration.AuditLists? = nil) throws -> Configuration {
        let auditLists = try auditLists ?? auditListsFromCFPrefs()
        var config = try Configuration(
            auditLists: auditLists,
            openTelemetryEndpoint: openTelemetryEndpointFromCFPrefs(),
            openTelemetry: .init(defaultBackoff: .milliseconds(10), maxBackoff: .seconds(30)),
            publishFailureThreshold: 5,
            useOpenTelemetry: true,
            defaultHistogramBuckets: preferencesArrayValue("DefaultHistogramBuckets") ?? [],
            auditLogThrottleInterval: .seconds(preferencesIntegerValue("AuditLogThrottleIntervalSeconds") ?? kCloudMetricsAuditLogThrottleIntervalDefault),
            requireAllowList: preferencesBoolValue("RequireAllowList") ?? false,
            keySource: keySourceFromCFPrefs(),
            destinations: destinationsFromCFPrefs(),
            defaultDestination: defaultDestinationFromCFPrefs(),
            configuredLabels: preferencesDictionaryValue("GlobalLabels") ?? [:]
        )
        try config.updateDefaultDestination()
        return config
    }

    private static func checkAndConvert<T>(dict: NSDictionary, key: String, defaultValue: T) -> T {
        if dict[key] != nil {
            if let value = dict[key] as? T {
                return value
            } else {
                Self.logger.error("""
                    Can't convert value. \
                    value=\(String(describing: dict[key]), privacy: .public) \
                    type=\(T.self, privacy: .public)
                    """)
            }
            return defaultValue
        }
        return defaultValue
    }
}
