#include "moonbit.h"
#include "values.h"
extern int32_t moon2nix_helper(void);
extern int32_t moon2nix_extra(void);
int32_t moon2nix_value(void) { return MOON2NIX_BASE + moon2nix_helper() + moon2nix_extra(); }
