import sys
from pathlib import Path
if sys.argv[1] == "header":
    Path(sys.argv[3]).write_text("#define VALUE " + Path(sys.argv[2]).read_text())
else:
    Path(sys.argv[3]).write_text('#include "moonbit.h"\n#include "value.h"\nint32_t generated_value(void) { return VALUE; }\n')
    Path(sys.argv[4]).write_text('extern "C" fn generated() -> Int = "generated_value"\n')
