// STB single-compilation-unit implementation file.
// This compiles stb_image, stb_image_resize2, and stb_image_write
// into one object file for linking with the Zig build.

#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#define STB_IMAGE_RESIZE_IMPLEMENTATION
#include "stb_image_resize2.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
