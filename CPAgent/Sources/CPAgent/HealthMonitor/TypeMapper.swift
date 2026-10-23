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

import FleetManagerClient
import Foundation
import GPUHealthDaemonClient
import SwiftProtobuf

enum TypeMapper {
    static func convertTelemetryResponse(_ response: GpuHealth_V1_GetTelemetryResponse)
        -> FleetManagerClient.Schemas.GpuDaemonTelemetry
    {
        .init(
            uptime: response.hasUptime ? durationToISO8601(response.uptime) : nil,
            updatedAt: response.hasUpdatedAt ? response.updatedAt.date : nil,
            expectedGpus: Int32(bitPattern: response.expectedGpus),
            availableGpus: Int32(bitPattern: response.availableGpus),
            gpus: response.gpus.map(convertGpuTelemetry)
        )
    }

    static func durationToISO8601(_ duration: SwiftProtobuf.Google_Protobuf_Duration) -> String {
        let total = duration.seconds
        if total == 0 { return "PT0S" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        var s = "PT"
        if hours > 0 { s += "\(hours)H" }
        if minutes > 0 { s += "\(minutes)M" }
        if seconds > 0 { s += "\(seconds)S" }
        return s
    }

    static func convertGpuTelemetry(_ gpu: GpuHealth_V1_GpuTelemetry)
        -> FleetManagerClient.Schemas.GpuTelemetry
    {
        .init(
            uuid: gpu.uuid,
            index: Int32(bitPattern: gpu.index),
            healthStatus: mapGpuHealthStatus(gpu.healthStatus),
            temperatureC: gpu.hasTemperatureC ? Int32(bitPattern: gpu.temperatureC) : nil,
            slowdownThresholdC: gpu.hasSlowdownThresholdC ? Int32(bitPattern: gpu.slowdownThresholdC) : nil,
            shutdownThresholdC: gpu.hasShutdownThresholdC ? Int32(bitPattern: gpu.shutdownThresholdC) : nil,
            throttleReasons: gpu.throttleReasons.map(mapThrottleReason),
            pagesPendingRetirement: gpu.hasPagesPendingRetirement
                ? gpu.pagesPendingRetirement : nil,
            sbeVolatileCount: gpu.hasSbeVolatileCount ? Int64(bitPattern: gpu.sbeVolatileCount) : nil,
            nvlinks: gpu.nvlinks.map(convertNvLinkStatus),
            powerUsageMw: gpu.hasPowerUsageMw ? Int32(bitPattern: gpu.powerUsageMw) : nil,
            powerLimitMw: gpu.hasPowerLimitMw ? Int32(bitPattern: gpu.powerLimitMw) : nil,
            gpuUtilizationPercent: gpu.hasGpuUtilizationPercent
                ? Int32(bitPattern: gpu.gpuUtilizationPercent) : nil,
            memoryUtilizationPercent: gpu.hasMemoryUtilizationPercent
                ? Int32(bitPattern: gpu.memoryUtilizationPercent) : nil,
            memoryTotalBytes: gpu.hasMemoryTotalBytes ? Int64(bitPattern: gpu.memoryTotalBytes) : nil,
            memoryUsedBytes: gpu.hasMemoryUsedBytes ? Int64(bitPattern: gpu.memoryUsedBytes) : nil,
            updatedAt: gpu.hasUpdatedAt ? gpu.updatedAt.date : nil,
            totalEnergyConsumptionMillij: gpu.hasTotalEnergyConsumptionMj
                ? Int64(bitPattern: gpu.totalEnergyConsumptionMj) : nil,
            rowRemapperHistogram: gpu.hasRowRemapperHistogram
                ? convertRowRemapperHistogram(gpu.rowRemapperHistogram) : nil,
            remappedRows: gpu.hasRemappedRows ? convertRemappedRows(gpu.remappedRows) : nil
        )
    }

    static func convertNvLinkStatus(_ link: GpuHealth_V1_NvLinkStatus)
        -> FleetManagerClient.Schemas.NvLinkStatus
    {
        .init(
            link: Int32(bitPattern: link.link),
            enabled: link.enabled,
            replayErrors: link.hasReplayErrors ? Int64(bitPattern: link.replayErrors) : nil,
            recoveryErrors: link.hasRecoveryErrors ? Int64(bitPattern: link.recoveryErrors) : nil,
            crcFlitErrors: link.hasCrcFlitErrors ? Int64(bitPattern: link.crcFlitErrors) : nil,
            crcDataErrors: link.hasCrcDataErrors ? Int64(bitPattern: link.crcDataErrors) : nil
        )
    }

    static func convertRowRemapperHistogram(
        _ h: GpuHealth_V1_RowRemapperHistogram
    ) -> FleetManagerClient.Schemas.RowRemapperHistogram {
        .init(
            max: Int32(bitPattern: h.max),
            high: Int32(bitPattern: h.high),
            partial: Int32(bitPattern: h.partial),
            low: Int32(bitPattern: h.low),
            none: Int32(bitPattern: h.none)
        )
    }

    static func convertRemappedRows(_ r: GpuHealth_V1_RemappedRows)
        -> FleetManagerClient.Schemas.RemappedRows
    {
        .init(
            correctable: Int64(bitPattern: r.correctable),
            uncorrectable: Int64(bitPattern: r.uncorrectable),
            pending: r.pending,
            failureEccurred: r.failureOccurred
        )
    }

    static func convertXidEvent(_ event: GpuHealth_V1_XidEvent)
        -> FleetManagerClient.Schemas.XidEvent
    {
        .init(
            detectedAt: event.hasDetectedAt ? event.detectedAt.date : nil,
            uuid: event.uuid,
            index: Int32(bitPattern: event.index),
            xid: Int32(bitPattern: event.xid),
            severity: mapXidSeverity(event.severity),
            action: mapXidAction(event.action)
        )
    }

    static func mapGpuHealthStatus(_ status: GpuHealth_V1_GpuHealthStatus)
        -> FleetManagerClient.Schemas.GpuTelemetry.healthStatusPayload
    {
        switch status {
        case .healthy: return .GPU_HEALTH_STATUS_HEALTHY
        case .degraded: return .GPU_HEALTH_STATUS_DEGRADED
        case .failed: return .GPU_HEALTH_STATUS_FAILED
        case .lost: return .GPU_HEALTH_STATUS_LOST
        default: return .GPU_HEALTH_STATUS_UNSPECIFIED
        }
    }

    static func mapThrottleReason(_ reason: Nvidia_V1_ThrottleReason)
        -> FleetManagerClient.Schemas.GpuTelemetry.throttleReasonsPayloadPayload
    {
        switch reason {
        case .gpuIdle: return .THROTTLE_REASON_GPU_IDLE
        case .applicationsClocksSetting: return .THROTTLE_REASON_APPLICATIONS_CLOCKS_SETTING
        case .swPowerCap: return .THROTTLE_REASON_SW_POWER_CAP
        case .hwSlowdown: return .THROTTLE_REASON_HW_SLOWDOWN
        case .syncBoost: return .THROTTLE_REASON_SYNC_BOOST
        case .swThermalSlowdown: return .THROTTLE_REASON_SW_THERMAL_SLOWDOWN
        case .hwThermalSlowdown: return .THROTTLE_REASON_HW_THERMAL_SLOWDOWN
        case .hwPowerBrakeSlowdown: return .THROTTLE_REASON_HW_POWER_BRAKE_SLOWDOWN
        case .displayClocksSetting: return .THROTTLE_REASON_DISPLAY_CLOCKS_SETTING
        default: return .THROTTLE_REASON_UNSPECIFIED
        }
    }

    static func mapXidSeverity(_ severity: Nvidia_V1_XidSeverity)
        -> FleetManagerClient.Schemas.XidEvent.severityPayload
    {
        switch severity {
        case .info: return .XID_SEVERITY_INFO
        case .warning: return .XID_SEVERITY_WARNING
        case .critical: return .XID_SEVERITY_CRITICAL
        default: return .XID_SEVERITY_UNSPECIFIED
        }
    }

    static func mapXidAction(_ action: Nvidia_V1_XidAction)
        -> FleetManagerClient.Schemas.XidEvent.actionPayload
    {
        switch action {
        case .ignore: return .XID_ACTION_IGNORE
        case .ignoreSympathetic: return .XID_ACTION_IGNORE_SYMPATHETIC
        case .informational: return .XID_ACTION_INFORMATIONAL
        case .restartApp: return .XID_ACTION_RESTART_APP
        case .resetGpu: return .XID_ACTION_RESET_GPU
        case .restartBm: return .XID_ACTION_RESTART_BM
        case .restartVm: return .XID_ACTION_RESTART_VM
        case .updateSwfw: return .XID_ACTION_UPDATE_SWFW
        case .checkMechanicals: return .XID_ACTION_CHECK_MECHANICALS
        case .checkUvm: return .XID_ACTION_CHECK_UVM
        case .contactSupport: return .XID_ACTION_CONTACT_SUPPORT
        case .investigateSw: return .XID_ACTION_INVESTIGATE_SW
        case .investigateSwUser: return .XID_ACTION_INVESTIGATE_SW_USER
        case .investigateSwUserLinkSi: return .XID_ACTION_INVESTIGATE_SW_USER_LINK_SI
        case .investigateHost: return .XID_ACTION_INVESTIGATE_HOST
        case .investigateLinkSi: return .XID_ACTION_INVESTIGATE_LINK_SI
        case .investigateLinkSiAndCables: return .XID_ACTION_INVESTIGATE_LINK_SI_AND_CABLES
        case .investigatePeerDevice: return .XID_ACTION_INVESTIGATE_PEER_DEVICE
        case .reportIssue: return .XID_ACTION_REPORT_ISSUE
        case .sympatheticReportSolo: return .XID_ACTION_SYMPATHETIC_REPORT_SOLO
        case .workflowXid13: return .XID_ACTION_WORKFLOW_XID_13
        case .workflowXid31: return .XID_ACTION_WORKFLOW_XID_31
        case .workflowXid45: return .XID_ACTION_WORKFLOW_XID_45
        case .workflowXid48: return .XID_ACTION_WORKFLOW_XID_48
        case .workflowNvlinkErr: return .XID_ACTION_WORKFLOW_NVLINK_ERR
        case .workflowNvlink5Err: return .XID_ACTION_WORKFLOW_NVLINK5_ERR
        case .checkNvlinkFailureFlow: return .XID_ACTION_CHECK_NVLINK_FAILURE_FLOW
        case .xid137Flow: return .XID_ACTION_XID_137_FLOW
        case .xid154: return .XID_ACTION_XID_154
        case .xid154Eval: return .XID_ACTION_XID_154_EVAL
        default: return .XID_ACTION_UNSPECIFIED
        }
    }
}
