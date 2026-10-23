#pragma once

#include "ehprobe.h"

void log_handler(ehprobe_log_level_t level, const char *message);
int event_handler(const ehprobe_event_t *event, void *user_context);
