# Reuse only a complete release for both package managers and every target.
def complete($version):
    . as $release
    | ["apk", "ipk"] | all(. as $format
        | ["aarch64_cortex-a53", "aarch64_cortex-a72", "aarch64_generic",
           "arm_cortex-a7_neon-vfpv4", "arm_cortex-a9_neon",
           "mipsel_24kc", "mips_24kc", "x86_64"]
        | all(. as $arch | any($release.assets[]?;
            (.name | startswith("xray-xkop-" + $version + "-"))
            and (.name | endswith("-" + $arch + "." + $format)))));
[.[] | select(.draft != true and .prerelease != true)
    | select(complete($version)) | .tag_name] | first // empty
