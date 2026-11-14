#include "../FFWorseQueryPolicy.h"
#include <stdio.h>

int main(void) {
    const struct { long major, minor, patch; const char *build; bool expected; } cases[] = {
        {18, 7, 1, "", false}, {25, 0, 0, "", false},
        {26, -1, 0, "", false}, {26, 0, -1, "", false},
        {26, 0, 0, "", true}, {26, 6, 2, "", true},
        {26, 7, 0, "", true}, {26, 7, 2, "", true},
        {26, 7, 3, "", false}, {26, 8, 0, "", false},
        {27, 0, 0, "24A", true}, {27, 1, 0, "24B", true},
        {27, 2, 0, "24C", true}, {27, 2, 1, "24C", true},
        {27, 2, 2, "24C", false},
        {27, 3, 0, "24C5037i", true},
        {27, 3, 0, "24C5037j", false}, {27, 3, 0, "24C5037i-extra", false},
        {27, 3, 0, "24C100", false}, {27, 3, 0, NULL, false},
        {27, 3, 0, "", false}, {27, 3, 1, "24C5037i", false},
        {27, 4, 0, "24C5037i", false}, {28, 3, 0, "24C5037i", false},
    };
    for (unsigned i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        if (FFWorseQueryVersionSupported(cases[i].major, cases[i].minor,
                                        cases[i].patch, cases[i].build) != cases[i].expected) {
            fprintf(stderr, "version policy case %u failed\n", i);
            return 1;
        }
    }
    puts("PASS: 24 version/build boundary cases");
    return 0;
}
