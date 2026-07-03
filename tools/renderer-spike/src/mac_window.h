#ifndef MAC_WINDOW_H
#define MAC_WINDOW_H

#include <stdbool.h>

void forge_mac_init(void);
void forge_mac_run(void);
void forge_mac_create_window(const char* title, int width, int height);
void forge_mac_shape_text(const char* text);

#endif
