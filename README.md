# build-llama.cpp-vulkan

Custom build script for optimized Vulkan backend

Introduces a comprehensive build script to automate llama.cpp compilation specifically tuned for AMD Ryzen 5 5600X and Radeon RX 6800 hardware.

- Configures CMAKE with specific flags for native Zen 3 CPU kernels and ccache for fast rebuilds.
- Automatically checks for required dependencies like glslc and SPIRV-Headers, installing them if necessary.
- Includes GPU detection via vulkaninfo to report target hardware and shader codegen tuning.
- Provides a smoke test suite to verify that the Vulkan backend successfully offloads computation on the target GPU.