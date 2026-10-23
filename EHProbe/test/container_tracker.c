#include "container_tracker.h"
#include "ehprobe.h"
#include <stdio.h>
#include <stdlib.h>

typedef struct container_node {
    uint64_t container_id;
    struct container_node *next;
} container_node_t;

static container_node_t *active_containers = NULL;

void track_container(uint64_t container_id) {
    container_node_t *node = malloc(sizeof(container_node_t));
    if (node) {
        node->container_id = container_id;
        node->next = active_containers;
        active_containers = node;
    }
}

void untrack_container(uint64_t container_id) {
    container_node_t **current = &active_containers;
    while (*current) {
        if ((*current)->container_id == container_id) {
            container_node_t *to_remove = *current;
            *current = (*current)->next;
            free(to_remove);
            return;
        }
        current = &(*current)->next;
    }
}

void cleanup_all_containers(void) {
    while (active_containers) {
        uint64_t container_id = active_containers->container_id;
        printf("Cleaning up container %lu allowlist...\n", container_id);
        ehprobe_remove_container_from_exec_allowlist(container_id);
        
        container_node_t *next = active_containers->next;
        free(active_containers);
        active_containers = next;
    }
}
