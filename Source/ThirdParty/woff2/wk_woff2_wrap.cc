#include "woff2_dec.h"
#include <cstddef>
#include <cstdint>

extern "C" size_t WK_woff2_ComputeFinalSize(const uint8_t* data, size_t length)
{
    return woff2::ComputeWOFF2FinalSize(data, length);
}

extern "C" bool WK_woff2_ConvertToTTF(uint8_t* result, size_t result_length, const uint8_t* data, size_t length)
{
    return woff2::ConvertWOFF2ToTTF(result, result_length, data, length);
}
