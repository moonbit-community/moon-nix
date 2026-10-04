#include "moonbit.h"
#include "values.h"
extern int32_t moon_nix_helper(void);
extern int32_t moon_nix_extra(void);
int32_t moon_nix_value(void) { return MOON_NIX_BASE + moon_nix_helper() + moon_nix_extra(); }
