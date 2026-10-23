// ehprobe_event.c - Event handling implementation
#include <string.h>
#include "ehprobe_internal.h"
#include "events.h"

int ringbuf_event_callback(void *ctx, void *data, size_t data_sz) {
    struct ehevent_header *hdr = (struct ehevent_header *)data;
    
    report_log(EHPROBE_LOG_DEBUG, "Received event: size=%zu, event_id=%u, pid=%u", 
               data_sz, hdr->event_id, hdr->pid);
    
    // Validate size
    if (data_sz < sizeof(*hdr)) {
        report_log(EHPROBE_LOG_ERROR, 
                   "Event too small: %zu bytes (minimum %zu)", 
                   data_sz, sizeof(*hdr));
        return 0;
    }
    
    if (data_sz != hdr->total_size) {
        report_log(EHPROBE_LOG_WARNING,
                   "Event size mismatch: expected %u, got %zu",
                   hdr->total_size, data_sz);
        return 0;
    }
    
    // Check if we should process this event based on features
    bool should_process = false;
    switch (hdr->event_id) {
    case EVENT_TYPE_FORK:
    case EVENT_TYPE_EXEC:
    case EVENT_TYPE_EXIT:
    case EVENT_TYPE_BPRM_CHECK:
    case EVENT_TYPE_SETUID:
    case EVENT_TYPE_SETGID:
        should_process = (g_ehprobe.config.features & EHPROBE_FEATURE_EXEC) != 0;
        break;
    case EVENT_TYPE_TASK_KILL:
        should_process = (g_ehprobe.config.features & EHPROBE_FEATURE_BLOCK_KILL) != 0;
        break;
    case EVENT_TYPE_FILE_OPEN:
    case EVENT_TYPE_PATH_CHMOD:
    case EVENT_TYPE_FILE_WRITE:
    case EVENT_TYPE_FILE_UNLINK:
        should_process = (g_ehprobe.config.features & EHPROBE_FEATURE_FS) != 0;
        break;
    case EVENT_TYPE_EXEC_SECURITY:
        should_process = (g_ehprobe.config.features & EHPROBE_FEATURE_BLOCK_EXEC) != 0;
        break;
    case EVENT_TYPE_BLOCK_KILL:
        should_process = (g_ehprobe.config.features & EHPROBE_FEATURE_BLOCK_KILL) != 0;
        break;
    case EVENT_TYPE_NEW_FS_EXEC:
        should_process = (g_ehprobe.config.features & EHPROBE_FEATURE_BLOCK_EXEC) != 0;
        break;
    case EVENT_TYPE_CONTAINER_START:
    case EVENT_TYPE_CONTAINER_STOP:
        should_process = true;
        break;
    case EVENT_TYPE_DEVICE_OPEN:
        should_process = (g_ehprobe.config.features & EHPROBE_FEATURE_FS) != 0;
        break;
    case EVENT_TYPE_NET_TCP:
    case EVENT_TYPE_NET_UDP:
    case EVENT_TYPE_DNS:
    case EVENT_TYPE_NET_ICMP:
        should_process = (g_ehprobe.config.features & EHPROBE_FEATURE_NETWORK) != 0;
        break;
    case EVENT_TYPE_AF_ALG_BIND:
        should_process = (g_ehprobe.config.features & EHPROBE_FEATURE_AF_ALG) != 0;
        break;
    case EVENT_TYPE_MODULE_LOAD_REQUEST:
        should_process = (g_ehprobe.config.features & EHPROBE_FEATURE_MODULE_LOAD) != 0;
        break;
    case EVENT_TYPE_XFRM_SA_NEW:
        should_process = (g_ehprobe.config.features & EHPROBE_FEATURE_XFRM_SA_NEW) != 0;
        break;
    case EVENT_TYPE_PACKET_DATA:
        should_process = (g_ehprobe.config.features & EHPROBE_FEATURE_DPI) != 0;
        break;
    case EVENT_TYPE_SCRIPT_SECURITY:
    case EVENT_TYPE_SCRIPT_FILE_CHECK:
        should_process = (g_ehprobe.config.features & EHPROBE_FEATURE_BLOCK_SCRIPT) != 0;
        break;
    default:
        report_log(EHPROBE_LOG_WARNING, "Unknown event type: %u", hdr->event_id);
        return 0;
    }

    if (!should_process) {
        report_log(EHPROBE_LOG_DEBUG, "Skipping event type %u (not enabled)", hdr->event_id);
        return 0;
    }
    
    // Build event structure with pointer to raw data
    ehprobe_event_t event = {
        .timestamp_ns = hdr->timestamp_ns,
        .pid = hdr->pid,
        .event_type = (ehprobe_event_type_t)hdr->event_id,
        .param_count = hdr->param_count,
        .total_size = hdr->total_size,
        .raw_data = (const uint8_t *)data
    };
    
    // Call user's event handler
    if (g_ehprobe.config.event_handler) {
        report_log(EHPROBE_LOG_DEBUG, "Calling event handler for event type %u", event.event_type);
        g_ehprobe.handler_return = g_ehprobe.config.event_handler(&event, g_ehprobe.config.user_context);
        g_ehprobe.events_processed++;
        
        // Non-zero return means stop processing
        if (g_ehprobe.handler_return != 0) {
            report_log(EHPROBE_LOG_DEBUG, "Event handler requested stop (return=%d)", 
                       g_ehprobe.handler_return);
            return 1;
        }
    }
    
    return 0;
}

int ehprobe_get_param(const ehprobe_event_t *event, uint16_t index, ehprobe_param_t *param) {
    if (!event || !param || !event->raw_data) {
        return EHPROBE_ERROR_INVALID_PARAM;
    }
    
    if (index >= event->param_count) {
        return EHPROBE_ERROR_INVALID_PARAM;
    }
    
    const struct ehevent_header *hdr = (const struct ehevent_header *)event->raw_data;
    const uint8_t *event_data = event->raw_data;
    
    // Get param_header array (starts right after ehevent_header)
    const struct param_header *param_headers = (const struct param_header *)(event_data + sizeof(*hdr));
    
    // Get the param_header for the requested index
    const struct param_header *phdr = &param_headers[index];
    
    // Fill param structure
    param->type = (ehprobe_param_type_t)phdr->type;
    param->length = phdr->length;
    
    // Get parameter data using the offset
    const uint8_t *param_data = event_data + phdr->offset;
    
    // Parse value based on type
    switch (phdr->type) {
    case PARAM_TYPE_NONE:
        break;
        
    case PARAM_TYPE_U32:
        if (phdr->length != sizeof(uint32_t)) {
            return EHPROBE_ERROR_INVALID_PARAM;
        }
        memcpy(&param->value.u32, param_data, sizeof(uint32_t));
        break;
        
    case PARAM_TYPE_U64:
        if (phdr->length != sizeof(uint64_t)) {
            return EHPROBE_ERROR_INVALID_PARAM;
        }
        memcpy(&param->value.u64, param_data, sizeof(uint64_t));
        break;
        
    case PARAM_TYPE_S32:
        if (phdr->length != sizeof(int32_t)) {
            return EHPROBE_ERROR_INVALID_PARAM;
        }
        memcpy(&param->value.s32, param_data, sizeof(int32_t));
        break;
        
    case PARAM_TYPE_S64:
        if (phdr->length != sizeof(int64_t)) {
            return EHPROBE_ERROR_INVALID_PARAM;
        }
        memcpy(&param->value.s64, param_data, sizeof(int64_t));
        break;
        
    case PARAM_TYPE_STRING:
        param->value.str = (const char *)param_data;
        break;
        
    case PARAM_TYPE_BYTEBUF:
        param->value.bytebuf = (const unsigned char *)param_data;
        break;
        
    default:
        return EHPROBE_ERROR_INVALID_PARAM;
    }
    
    return EHPROBE_SUCCESS;
}

const char *ehprobe_param_type_str(ehprobe_param_type_t param_type) {
    switch (param_type) {
    case EHPROBE_PARAM_NONE:   return "NONE";
    case EHPROBE_PARAM_U32:    return "U32";
    case EHPROBE_PARAM_U64:    return "U64";
    case EHPROBE_PARAM_S32:    return "S32";
    case EHPROBE_PARAM_S64:    return "S64";
    case EHPROBE_PARAM_STRING: return "STRING";
    case EHPROBE_PARAM_BYTEBUF: return "BYTEBUF";
    default:                   return "UNKNOWN";
    }
}
