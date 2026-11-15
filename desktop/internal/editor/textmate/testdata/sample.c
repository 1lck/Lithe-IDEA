/* A small C file. */
#include <stdio.h>
#include "local.h"

#define MAX(a, b) ((a) > (b) ? (a) : (b))
#define NAME "sample"
#ifndef SIZE
#  define SIZE 16
#endif

typedef struct node {
    int value;
    struct node *next;
} node_t;

enum color { RED, GREEN = 2, BLUE };

static const char *names[] = { "a", "b\n", NULL };

// Sums a list.
static int sum(const node_t *head) {
    int total = 0;
    for (const node_t *n = head; n != NULL; n = n->next) {
        total += n->value;
    }
    return total;
}

int main(int argc, char **argv) {
    unsigned long mask = 0xFFul;
    double ratio = 1.5e-3;
    char c = '\'';
    node_t second = { .value = 2, .next = NULL };
    node_t first = { 1, &second };
    if (argc > 1 && argv[1][0] == '-') {
        printf("%s: %d\n", NAME, MAX(sum(&first), SIZE));
    } else {
        switch (argc) {
        case 0:
            break;
        default:
            goto done;
        }
    }
done:
    (void)mask; (void)ratio; (void)c; (void)names;
    return sizeof(node_t) > 0 ? 0 : 1;
}
