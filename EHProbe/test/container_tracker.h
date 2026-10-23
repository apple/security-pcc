#pragma once

#include <stdint.h>

void track_container(uint64_t container_id);
void untrack_container(uint64_t container_id);
void cleanup_all_containers(void);
