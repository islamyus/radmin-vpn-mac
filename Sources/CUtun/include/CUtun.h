#pragma once
#include <stddef.h>
int rvpn_open_utun(char *name, size_t capacity);
int rvpn_connect_bridge(const char *path, unsigned int owner);
int rvpn_listen_service(unsigned int owner);
int rvpn_accept_service(int listener, unsigned int owner);
