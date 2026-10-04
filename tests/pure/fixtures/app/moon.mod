// Root has dependencies from two compatibility groups transitively.
name = "test/app"
version = "0.1.0"
import { "test/lib@0.1.0", "test/bridge@1.0.0" }
options(source: "src")
supported_targets = "all - native + native"
