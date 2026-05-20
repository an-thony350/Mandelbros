#ifndef CRC8_H
#define CRC8_H

#include <stdint.h>
#include <stddef.h>

uint8_t crc8_ccitt(const uint8_t *buf, size_t len);

#endif // CRC8_H