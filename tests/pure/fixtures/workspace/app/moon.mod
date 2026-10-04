name = "work/app"
version = "0.1.0"
import { "work/shared@1.0.0" }
options(source: "src")
rule(name: "copy", command: "cat $input > $output")
rule(name: "generate", command: "python3 $mod_dir/generate.py $input $output")
