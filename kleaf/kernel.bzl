# Copyright (C) 2021 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

load("//build/bazel_common_rules/dist:dist.bzl", "copy_to_dist_dir")
load("//build/bazel_common_rules/exec:exec.bzl", "exec")
load(
    "//build/kernel/kleaf/impl:common_providers.bzl",
    "KernelBuildAbiInfo",
    "KernelBuildExtModuleInfo",
    "KernelBuildInTreeModulesInfo",
    "KernelBuildInfo",
    "KernelBuildUapiInfo",
    "KernelEnvInfo",
    "KernelModuleInfo",
    "KernelUnstrippedModulesInfo",
)
load("//build/kernel/kleaf/impl:debug.bzl", "debug")
load("//build/kernel/kleaf/impl:kernel_build.bzl", _kernel_build_macro = "kernel_build")
load("//build/kernel/kleaf/impl:kernel_build_config.bzl", _kernel_build_config = "kernel_build_config")
load("//build/kernel/kleaf/impl:kernel_dtstree.bzl", "DtstreeInfo", _kernel_dtstree = "kernel_dtstree")
load("//build/kernel/kleaf/impl:srcs_aspect.bzl", "SrcsInfo", "srcs_aspect")
load("//build/kernel/kleaf/impl:stamp.bzl", "stamp")
load("//build/kernel/kleaf/impl:btf.bzl", "btf")
load(":directory_with_structure.bzl", dws = "directory_with_structure")
load(":hermetic_tools.bzl", "HermeticToolsInfo")
load(":update_source_file.bzl", "update_source_file")
load(
    "//build/kernel/kleaf/impl:utils.bzl",
    "find_file",
    "find_files",
    "kernel_utils",
    "utils",
)
load(
    "//build/kernel/kleaf/artifact_tests:kernel_test.bzl",
    "kernel_module_test",
)

# Re-exports
kernel_build = _kernel_build_macro
kernel_build_config = _kernel_build_config
kernel_dtstree = _kernel_dtstree

_sibling_names = [
    "notrim",
    "with_vmlinux",
]

def _kernel_module_impl(ctx):
    kernel_utils.check_kernel_build(ctx.attr.kernel_module_deps, ctx.attr.kernel_build, ctx.label)

    inputs = []
    inputs += ctx.files.srcs
    inputs += ctx.attr.kernel_build[KernelEnvInfo].dependencies
    inputs += ctx.attr.kernel_build[KernelBuildExtModuleInfo].modules_prepare_deps
    inputs += ctx.attr.kernel_build[KernelBuildExtModuleInfo].module_srcs
    inputs += ctx.files.makefile
    inputs += [
        ctx.file._search_and_cp_output,
        ctx.file._check_declared_output_list,
    ]
    for kernel_module_dep in ctx.attr.kernel_module_deps:
        inputs += kernel_module_dep[KernelEnvInfo].dependencies

    modules_staging_dws = dws.make(ctx, "{}/staging".format(ctx.attr.name))
    kernel_uapi_headers_dws = dws.make(ctx, "{}/kernel-uapi-headers.tar.gz_staging".format(ctx.attr.name))
    outdir = modules_staging_dws.directory.dirname

    unstripped_dir = None
    if ctx.attr.kernel_build[KernelBuildExtModuleInfo].collect_unstripped_modules:
        unstripped_dir = ctx.actions.declare_directory("{name}/unstripped".format(name = ctx.label.name))

    # Original `outs` attribute of `kernel_module` macro.
    original_outs = []

    # apply basename to all of original_outs
    original_outs_base = []

    for out in ctx.outputs.outs:
        # outdir includes target name at the end already. So short_name is the original
        # token in `outs` of `kernel_module` macro.
        # e.g. kernel_module(name = "foo", outs = ["bar"])
        #   => _kernel_module(name = "foo", outs = ["foo/bar"])
        #   => outdir = ".../foo"
        #      ctx.outputs.outs = [File(".../foo/bar")]
        #   => short_name = "bar"
        short_name = out.path[len(outdir) + 1:]
        original_outs.append(short_name)
        original_outs_base.append(out.basename)

    all_module_names_file = ctx.actions.declare_file("{}/all_module_names.txt".format(ctx.label.name))
    ctx.actions.write(
        output = all_module_names_file,
        content = "\n".join(original_outs) + "\n",
    )
    inputs.append(all_module_names_file)

    module_symvers = ctx.actions.declare_file("{}/Module.symvers".format(ctx.attr.name))
    check_no_remaining = ctx.actions.declare_file("{name}/{name}.check_no_remaining".format(name = ctx.attr.name))
    command_outputs = [
        module_symvers,
        check_no_remaining,
    ]
    command_outputs += dws.files(modules_staging_dws)
    command_outputs += dws.files(kernel_uapi_headers_dws)
    if unstripped_dir:
        command_outputs.append(unstripped_dir)

    command = ""
    command += ctx.attr.kernel_build[KernelEnvInfo].setup
    command += ctx.attr.kernel_build[KernelBuildExtModuleInfo].modules_prepare_setup
    command += """
             # create dirs for modules
               mkdir -p {kernel_uapi_headers_dir}/usr
    """.format(
        kernel_uapi_headers_dir = kernel_uapi_headers_dws.directory.path,
    )
    for kernel_module_dep in ctx.attr.kernel_module_deps:
        command += kernel_module_dep[KernelEnvInfo].setup

    grab_unstripped_cmd = ""
    if unstripped_dir:
        grab_unstripped_cmd = """
            mkdir -p {unstripped_dir}
            {search_and_cp_output} --srcdir ${{OUT_DIR}}/${{ext_mod_rel}} --dstdir {unstripped_dir} {outs}
        """.format(
            search_and_cp_output = ctx.file._search_and_cp_output.path,
            unstripped_dir = unstripped_dir.path,
            # Use basenames to flatten the unstripped directory, even though outs may contain items with slash.
            outs = " ".join(original_outs_base),
        )

    scmversion_ret = stamp.get_ext_mod_scmversion(ctx)
    inputs += scmversion_ret.deps
    command += scmversion_ret.cmd

    command += """
             # Set variables
               if [ "${{DO_NOT_STRIP_MODULES}}" != "1" ]; then
                 module_strip_flag="INSTALL_MOD_STRIP=1"
               fi
               ext_mod_rel=$(rel_path ${{ROOT_DIR}}/{ext_mod} ${{KERNEL_DIR}})

             # Actual kernel module build
               make -C {ext_mod} ${{TOOL_ARGS}} M=${{ext_mod_rel}} O=${{OUT_DIR}} KERNEL_SRC=${{ROOT_DIR}}/${{KERNEL_DIR}}
             # Install into staging directory
               make -C {ext_mod} ${{TOOL_ARGS}} DEPMOD=true M=${{ext_mod_rel}} \
                   O=${{OUT_DIR}} KERNEL_SRC=${{ROOT_DIR}}/${{KERNEL_DIR}}     \
                   INSTALL_MOD_PATH=$(realpath {modules_staging_dir})          \
                   INSTALL_MOD_DIR=extra/{ext_mod}                             \
                   KERNEL_UAPI_HEADERS_DIR=$(realpath {kernel_uapi_headers_dir}) \
                   INSTALL_HDR_PATH=$(realpath {kernel_uapi_headers_dir}/usr)  \
                   ${{module_strip_flag}} modules_install

             # Check if there are remaining *.ko files
               remaining_ko_files=$({check_declared_output_list} \\
                    --declared $(cat {all_module_names_file}) \\
                    --actual $(cd {modules_staging_dir}/lib/modules/*/extra/{ext_mod} && find . -type f -name '*.ko' | sed 's:^[.]/::'))
               if [[ ${{remaining_ko_files}} ]]; then
                 echo "ERROR: The following kernel modules are built but not copied. Add these lines to the module_outs attribute of {label}:" >&2
                 for ko in ${{remaining_ko_files}}; do
                   echo '    "'"${{ko}}"'",' >&2
                 done
                 exit 1
               fi
               touch {check_no_remaining}

             # Grab unstripped modules
               {grab_unstripped_cmd}
             # Move Module.symvers
               mv ${{OUT_DIR}}/${{ext_mod_rel}}/Module.symvers {module_symvers}
               """.format(
        label = ctx.label,
        ext_mod = ctx.attr.ext_mod,
        module_symvers = module_symvers.path,
        modules_staging_dir = modules_staging_dws.directory.path,
        outdir = outdir,
        kernel_uapi_headers_dir = kernel_uapi_headers_dws.directory.path,
        check_declared_output_list = ctx.file._check_declared_output_list.path,
        all_module_names_file = all_module_names_file.path,
        grab_unstripped_cmd = grab_unstripped_cmd,
        check_no_remaining = check_no_remaining.path,
    )

    command += dws.record(modules_staging_dws)
    command += dws.record(kernel_uapi_headers_dws)

    debug.print_scripts(ctx, command)
    ctx.actions.run_shell(
        mnemonic = "KernelModule",
        inputs = inputs,
        outputs = command_outputs,
        command = command,
        progress_message = "Building external kernel module {}".format(ctx.label),
    )

    # Additional outputs because of the value in outs. This is
    # [basename(out) for out in outs] - outs
    additional_declared_outputs = []
    for short_name, out in zip(original_outs, ctx.outputs.outs):
        if "/" in short_name:
            additional_declared_outputs.append(ctx.actions.declare_file("{name}/{basename}".format(
                name = ctx.attr.name,
                basename = out.basename,
            )))
        original_outs_base.append(out.basename)
    cp_cmd_outputs = ctx.outputs.outs + additional_declared_outputs

    if cp_cmd_outputs:
        command = ctx.attr._hermetic_tools[HermeticToolsInfo].setup + """
             # Copy files into place
               {search_and_cp_output} --srcdir {modules_staging_dir}/lib/modules/*/extra/{ext_mod}/ --dstdir {outdir} {outs}
        """.format(
            search_and_cp_output = ctx.file._search_and_cp_output.path,
            modules_staging_dir = modules_staging_dws.directory.path,
            ext_mod = ctx.attr.ext_mod,
            outdir = outdir,
            outs = " ".join(original_outs),
        )
        debug.print_scripts(ctx, command, what = "cp_outputs")
        ctx.actions.run_shell(
            mnemonic = "KernelModuleCpOutputs",
            inputs = ctx.attr._hermetic_tools[HermeticToolsInfo].deps + [
                # We don't need structure_file here because we only care about files in the directory.
                modules_staging_dws.directory,
                ctx.file._search_and_cp_output,
            ],
            outputs = cp_cmd_outputs,
            command = command,
            progress_message = "Copying outputs {}".format(ctx.label),
        )

    setup = """
             # Use a new shell to avoid polluting variables
               (
             # Set variables
               # rel_path requires the existence of ${{ROOT_DIR}}/{ext_mod}, which may not be the case for
               # _kernel_modules_install. Make that.
               mkdir -p ${{ROOT_DIR}}/{ext_mod}
               ext_mod_rel=$(rel_path ${{ROOT_DIR}}/{ext_mod} ${{KERNEL_DIR}})
             # Restore Modules.symvers
               mkdir -p ${{OUT_DIR}}/${{ext_mod_rel}}
               cp {module_symvers} ${{OUT_DIR}}/${{ext_mod_rel}}/Module.symvers
             # New shell ends
               )
    """.format(
        ext_mod = ctx.attr.ext_mod,
        module_symvers = module_symvers.path,
    )

    # Only declare outputs in the "outs" list. For additional outputs that this rule created,
    # the label is available, but this rule doesn't explicitly return it in the info.
    # Also add check_no_remaining in the list of default outputs so that, when
    # outs is empty, the KernelModule action is still executed, and so
    # is check_declared_output_list.
    return [
        DefaultInfo(
            files = depset(ctx.outputs.outs + [check_no_remaining]),
            # For kernel_module_test
            runfiles = ctx.runfiles(files = ctx.outputs.outs),
        ),
        KernelEnvInfo(
            dependencies = [module_symvers],
            setup = setup,
        ),
        KernelModuleInfo(
            kernel_build = ctx.attr.kernel_build,
            modules_staging_dws = modules_staging_dws,
            kernel_uapi_headers_dws = kernel_uapi_headers_dws,
            files = ctx.outputs.outs,
        ),
        KernelUnstrippedModulesInfo(
            directory = unstripped_dir,
        ),
    ]

_kernel_module = rule(
    implementation = _kernel_module_impl,
    doc = """
""",
    attrs = {
        "srcs": attr.label_list(
            mandatory = True,
            allow_files = True,
        ),
        "makefile": attr.label_list(
            allow_files = True,
        ),
        "kernel_build": attr.label(
            mandatory = True,
            providers = [KernelEnvInfo, KernelBuildExtModuleInfo],
        ),
        "kernel_module_deps": attr.label_list(
            providers = [KernelEnvInfo, KernelModuleInfo],
        ),
        "ext_mod": attr.string(mandatory = True),
        # Not output_list because it is not a list of labels. The list of
        # output labels are inferred from name and outs.
        "outs": attr.output_list(),
        "_hermetic_tools": attr.label(default = "//build/kernel:hermetic-tools", providers = [HermeticToolsInfo]),
        "_search_and_cp_output": attr.label(
            allow_single_file = True,
            default = Label("//build/kernel/kleaf:search_and_cp_output.py"),
            doc = "Label referring to the script to process outputs",
        ),
        "_check_declared_output_list": attr.label(
            allow_single_file = True,
            default = Label("//build/kernel/kleaf:check_declared_output_list.py"),
        ),
        "_config_is_stamp": attr.label(default = "//build/kernel/kleaf:config_stamp"),
        "_debug_print_scripts": attr.label(default = "//build/kernel/kleaf:debug_print_scripts"),
    },
)

def kernel_module(
        name,
        kernel_build,
        outs = None,
        srcs = None,
        kernel_module_deps = None,
        **kwargs):
    """Generates a rule that builds an external kernel module.

    Example:
    ```
    kernel_module(
        name = "nfc",
        srcs = glob([
            "**/*.c",
            "**/*.h",

            # If there are Kbuild files, add them
            "**/Kbuild",
            # If there are additional makefiles in subdirectories, add them
            "**/Makefile",
        ]),
        outs = ["nfc.ko"],
        kernel_build = "//common:kernel_aarch64",
    )
    ```

    Args:
        name: Name of this kernel module.
        srcs: Source files to build this kernel module. If unspecified or value
          is `None`, it is by default the list in the above example:
          ```
          glob([
            "**/*.c",
            "**/*.h",
            "**/Kbuild",
            "**/Makefile",
          ])
          ```
        kernel_build: Label referring to the kernel_build module.
        kernel_module_deps: A list of other kernel_module dependencies.

          Before building this target, `Modules.symvers` from the targets in
          `kernel_module_deps` are restored, so this target can be built against
          them.
        outs: The expected output files. If unspecified or value is `None`, it
          is `["{name}.ko"]` by default.

          For each token `out`, the build rule automatically finds a
          file named `out` in the legacy kernel modules staging
          directory. The file is copied to the output directory of
          this package, with the label `name/out`.

          - If `out` doesn't contain a slash, subdirectories are searched.

            Example:
            ```
            kernel_module(name = "nfc", outs = ["nfc.ko"])
            ```

            The build system copies
            ```
            <legacy modules staging dir>/lib/modules/*/extra/<some subdir>/nfc.ko
            ```
            to
            ```
            <package output dir>/nfc.ko
            ```

            `nfc/nfc.ko` is the label to the file.

          - If `out` contains slashes, its value is used. The file is
            also copied to the top of package output directory.

            For example:
            ```
            kernel_module(name = "nfc", outs = ["foo/nfc.ko"])
            ```

            The build system copies
            ```
            <legacy modules staging dir>/lib/modules/*/extra/foo/nfc.ko
            ```
            to
            ```
            foo/nfc.ko
            ```

            `nfc/foo/nfc.ko` is the label to the file.

            The file is also copied to `<package output dir>/nfc.ko`.

            `nfc/nfc.ko` is the label to the file.

            See `search_and_cp_output.py` for details.
        kwargs: Additional attributes to the internal rule, e.g.
          [`visibility`](https://docs.bazel.build/versions/main/visibility.html).
          See complete list
          [here](https://docs.bazel.build/versions/main/be/common-definitions.html#common-attributes).
    """
    kwargs.update(
        # This should be the exact list of arguments of kernel_module.
        # Default arguments of _kernel_module go into _kernel_module_set_defaults.
        name = name,
        srcs = srcs,
        kernel_build = kernel_build,
        kernel_module_deps = kernel_module_deps,
        outs = outs,
    )
    kwargs = _kernel_module_set_defaults(kwargs)

    main_kwargs = dict(kwargs)
    main_kwargs["name"] = name
    main_kwargs["outs"] = ["{name}/{out}".format(name = name, out = out) for out in main_kwargs["outs"]]
    _kernel_module(**main_kwargs)

    kernel_module_test(
        name = name + "_test",
        modules = [name],
    )

    # Define external module for sibling kernel_build's.
    # It may be possible to optimize this to alias some of them with the same
    # kernel_build, but we don't have a way to get this information in
    # the load phase right now.
    for sibling_name in _sibling_names:
        sibling_kwargs = dict(kwargs)
        sibling_target_name = name + "_" + sibling_name
        sibling_kwargs["name"] = sibling_target_name
        sibling_kwargs["outs"] = ["{sibling_target_name}/{out}".format(sibling_target_name = sibling_target_name, out = out) for out in outs]

        # This assumes the target is a kernel_build_abi with define_abi_targets
        # etc., which may not be the case. See below for adding "manual" tag.
        # TODO(b/231647455): clean up dependencies on implementation details.
        sibling_kwargs["kernel_build"] = sibling_kwargs["kernel_build"] + "_" + sibling_name
        if sibling_kwargs.get("kernel_module_deps") != None:
            sibling_kwargs["kernel_module_deps"] = [dep + "_" + sibling_name for dep in sibling_kwargs["kernel_module_deps"]]

        # We don't know if {kernel_build}_{sibling_name} exists or not, so
        # add "manual" tag to prevent it from being built by default.
        sibling_kwargs["tags"] = sibling_kwargs.get("tags", []) + ["manual"]

        _kernel_module(**sibling_kwargs)

def _kernel_module_set_defaults(kwargs):
    """
    Set default values for `_kernel_module` that can't be specified in
    `attr.*(default=...)` in rule().
    """
    if kwargs.get("makefile") == None:
        kwargs["makefile"] = native.glob(["Makefile"])

    if kwargs.get("ext_mod") == None:
        kwargs["ext_mod"] = native.package_name()

    if kwargs.get("outs") == None:
        kwargs["outs"] = ["{}.ko".format(kwargs["name"])]

    if kwargs.get("srcs") == None:
        kwargs["srcs"] = native.glob([
            "**/*.c",
            "**/*.h",
            "**/Kbuild",
            "**/Makefile",
        ])

    return kwargs

def _kernel_modules_install_impl(ctx):
    kernel_utils.check_kernel_build(ctx.attr.kernel_modules, ctx.attr.kernel_build, ctx.label)

    # A list of declared files for outputs of kernel_module rules
    external_modules = []

    inputs = []
    inputs += ctx.attr.kernel_build[KernelEnvInfo].dependencies
    inputs += ctx.attr.kernel_build[KernelBuildExtModuleInfo].modules_prepare_deps
    inputs += ctx.attr.kernel_build[KernelBuildExtModuleInfo].module_srcs
    inputs += [
        ctx.file._search_and_cp_output,
        ctx.file._check_duplicated_files_in_archives,
        ctx.attr.kernel_build[KernelBuildExtModuleInfo].modules_staging_archive,
    ]
    for kernel_module in ctx.attr.kernel_modules:
        inputs += dws.files(kernel_module[KernelModuleInfo].modules_staging_dws)

        for module_file in kernel_module[KernelModuleInfo].files:
            declared_file = ctx.actions.declare_file("{}/{}".format(ctx.label.name, module_file.basename))
            external_modules.append(declared_file)

    modules_staging_dws = dws.make(ctx, "{}/staging".format(ctx.label.name))

    command = ""
    command += ctx.attr.kernel_build[KernelEnvInfo].setup
    command += ctx.attr.kernel_build[KernelBuildExtModuleInfo].modules_prepare_setup
    command += """
             # create dirs for modules
               mkdir -p {modules_staging_dir}
             # Restore modules_staging_dir from kernel_build
               tar xf {kernel_build_modules_staging_archive} -C {modules_staging_dir}
    """.format(
        modules_staging_dir = modules_staging_dws.directory.path,
        kernel_build_modules_staging_archive =
            ctx.attr.kernel_build[KernelBuildExtModuleInfo].modules_staging_archive.path,
    )
    for kernel_module in ctx.attr.kernel_modules:
        # Allow directories to be written because we are merging multiple directories into one.
        # However, don't allow files to be written because we don't expect modules to produce
        # conflicting files. check_duplicated_files_in_archives further enforces this.
        command += dws.restore(
            kernel_module[KernelModuleInfo].modules_staging_dws,
            dst = modules_staging_dws.directory.path,
            options = "-aL --chmod=D+w",
        )

    # TODO(b/194347374): maybe run depmod.sh with CONFIG_SHELL?
    command += """
             # Check if there are duplicated files in modules_staging_archive of
             # depended kernel_build and kernel_module's
               {check_duplicated_files_in_archives} {modules_staging_archives}
             # Set variables
               if [[ ! -f ${{OUT_DIR}}/include/config/kernel.release ]]; then
                   echo "ERROR: No ${{OUT_DIR}}/include/config/kernel.release" >&2
                   exit 1
               fi
               kernelrelease=$(cat ${{OUT_DIR}}/include/config/kernel.release 2> /dev/null)
               mixed_build_prefix=
               if [[ ${{KBUILD_MIXED_TREE}} ]]; then
                   mixed_build_prefix=${{KBUILD_MIXED_TREE}}/
               fi
               real_modules_staging_dir=$(realpath {modules_staging_dir})
             # Run depmod
               (
                 cd ${{OUT_DIR}} # for System.map when mixed_build_prefix is not set
                 INSTALL_MOD_PATH=${{real_modules_staging_dir}} ${{ROOT_DIR}}/${{KERNEL_DIR}}/scripts/depmod.sh depmod ${{kernelrelease}} ${{mixed_build_prefix}}
               )
             # Remove symlinks that are dead outside of the sandbox
               (
                 symlink="$(ls {modules_staging_dir}/lib/modules/*/source)"
                 if [[ -n "$symlink" ]] && [[ -L "$symlink" ]]; then rm "$symlink"; fi
                 symlink="$(ls {modules_staging_dir}/lib/modules/*/build)"
                 if [[ -n "$symlink" ]] && [[ -L "$symlink" ]]; then rm "$symlink"; fi
               )
    """.format(
        modules_staging_archives = " ".join(
            [ctx.attr.kernel_build[KernelBuildExtModuleInfo].modules_staging_archive.path] +
            [kernel_module[KernelModuleInfo].modules_staging_dws.directory.path for kernel_module in ctx.attr.kernel_modules],
        ),
        modules_staging_dir = modules_staging_dws.directory.path,
        check_duplicated_files_in_archives = ctx.file._check_duplicated_files_in_archives.path,
    )

    if external_modules:
        external_module_dir = external_modules[0].dirname
        command += """
                 # Move external modules to declared output location
                   {search_and_cp_output} --srcdir {modules_staging_dir}/lib/modules/*/extra --dstdir {outdir} {filenames}
        """.format(
            modules_staging_dir = modules_staging_dws.directory.path,
            outdir = external_module_dir,
            filenames = " ".join([declared_file.basename for declared_file in external_modules]),
            search_and_cp_output = ctx.file._search_and_cp_output.path,
        )

    command += dws.record(modules_staging_dws)

    debug.print_scripts(ctx, command)
    ctx.actions.run_shell(
        mnemonic = "KernelModulesInstall",
        inputs = inputs,
        outputs = external_modules + dws.files(modules_staging_dws),
        command = command,
        progress_message = "Running depmod {}".format(ctx.label),
    )

    return [
        DefaultInfo(files = depset(external_modules)),
        KernelModuleInfo(
            kernel_build = ctx.attr.kernel_build,
            modules_staging_dws = modules_staging_dws,
        ),
    ]

kernel_modules_install = rule(
    implementation = _kernel_modules_install_impl,
    doc = """Generates a rule that runs depmod in the module installation directory.

When including this rule to the `data` attribute of a `copy_to_dist_dir` rule,
all external kernel modules specified in `kernel_modules` are included in
distribution. This excludes `module_outs` in `kernel_build` to avoid conflicts.

Example:
```
kernel_modules_install(
    name = "foo_modules_install",
    kernel_build = ":foo",           # A kernel_build rule
    kernel_modules = [               # kernel_module rules
        "//path/to/nfc:nfc_module",
    ],
)
kernel_build(
    name = "foo",
    outs = ["vmlinux"],
    module_outs = ["core_module.ko"],
)
copy_to_dist_dir(
    name = "foo_dist",
    data = [
        ":foo",                      # Includes core_module.ko and vmlinux
        ":foo_modules_install",      # Includes nfc_module
    ],
)
```
In `foo_dist`, specifying `foo_modules_install` in `data` won't include
`core_module.ko`, because it is already included in `foo` in `data`.
""",
    attrs = {
        "kernel_modules": attr.label_list(
            providers = [KernelEnvInfo, KernelModuleInfo],
            doc = "A list of labels referring to `kernel_module`s to install. Must have the same `kernel_build` as this rule.",
        ),
        "kernel_build": attr.label(
            providers = [KernelEnvInfo, KernelBuildExtModuleInfo],
            doc = "Label referring to the `kernel_build` module.",
        ),
        "_debug_print_scripts": attr.label(default = "//build/kernel/kleaf:debug_print_scripts"),
        "_check_duplicated_files_in_archives": attr.label(
            allow_single_file = True,
            default = Label("//build/kernel/kleaf:check_duplicated_files_in_archives.py"),
            doc = "Label referring to the script to process outputs",
        ),
        "_search_and_cp_output": attr.label(
            allow_single_file = True,
            default = Label("//build/kernel/kleaf:search_and_cp_output.py"),
            doc = "Label referring to the script to process outputs",
        ),
    },
)

def _merged_kernel_uapi_headers_impl(ctx):
    kernel_build = ctx.attr.kernel_build
    base_kernel = kernel_build[KernelBuildUapiInfo].base_kernel

    # srcs and dws_srcs are the list of sources to merge.
    # Early elements = higher priority. srcs has higher priority than dws_srcs.
    srcs = []
    if base_kernel:
        srcs += base_kernel[KernelBuildUapiInfo].kernel_uapi_headers.files.to_list()
    srcs += kernel_build[KernelBuildUapiInfo].kernel_uapi_headers.files.to_list()
    dws_srcs = [kernel_module[KernelModuleInfo].kernel_uapi_headers_dws for kernel_module in ctx.attr.kernel_modules]

    inputs = srcs + ctx.attr._hermetic_tools[HermeticToolsInfo].deps
    for dws_src in dws_srcs:
        inputs += dws.files(dws_src)

    out_file = ctx.actions.declare_file("{}/kernel-uapi-headers.tar.gz".format(ctx.attr.name))
    intermediates_dir = utils.intermediates_dir(ctx)

    command = ""
    command += ctx.attr._hermetic_tools[HermeticToolsInfo].setup
    command += """
        mkdir -p {intermediates_dir}
    """.format(
        intermediates_dir = intermediates_dir,
    )

    # Extract the source tarballs in low to high priority order.
    for dws_src in reversed(dws_srcs):
        # Copy the directory over, overwriting existing files. Add write permission
        # targets with higher priority can overwrite existing files.
        command += dws.restore(
            dws_src,
            dst = intermediates_dir,
            options = "-aL --chmod=+w",
        )

    for src in reversed(srcs):
        command += """
            tar xf {src} -C {intermediates_dir}
        """.format(
            src = src.path,
            intermediates_dir = intermediates_dir,
        )

    command += """
        tar czf {out_file} -C {intermediates_dir} usr/
        rm -rf {intermediates_dir}
    """.format(
        out_file = out_file.path,
        intermediates_dir = intermediates_dir,
    )

    debug.print_scripts(ctx, command)
    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [out_file],
        progress_message = "Merging kernel-uapi-headers.tar.gz {}".format(ctx.label),
        command = command,
        mnemonic = "MergedKernelUapiHeaders",
    )
    return DefaultInfo(files = depset([out_file]))

merged_kernel_uapi_headers = rule(
    implementation = _merged_kernel_uapi_headers_impl,
    doc = """Merge `kernel-uapi-headers.tar.gz`.

On certain devices, kernel modules install additional UAPI headers. Use this
rule to add these module UAPI headers to the final `kernel-uapi-headers.tar.gz`.

If there are conflicts of file names in the source tarballs, files higher in
the list have higher priority:
1. UAPI headers from the `base_kernel` of the `kernel_build` (ususally the GKI build)
2. UAPI headers from the `kernel_build` (usually the device build)
3. UAPI headers from ``kernel_modules`. Order among the modules are undetermined.
""",
    attrs = {
        "kernel_build": attr.label(
            doc = "The `kernel_build`",
            mandatory = True,
            providers = [KernelBuildUapiInfo],
        ),
        "kernel_modules": attr.label_list(
            doc = """A list of external `kernel_module`s to merge `kernel-uapi-headers.tar.gz`""",
            providers = [KernelModuleInfo],
        ),
        "_hermetic_tools": attr.label(default = "//build/kernel:hermetic-tools", providers = [HermeticToolsInfo]),
        "_debug_print_scripts": attr.label(default = "//build/kernel/kleaf:debug_print_scripts"),
    },
)

def _build_modules_image_impl_common(
        ctx,
        what,
        outputs,
        build_command,
        modules_staging_dir,
        implicit_outputs = None,
        additional_inputs = None,
        mnemonic = None):
    """Command implementation for building images that directly contain modules.

    Args:
        ctx: ctx
        what: what is being built, for logging
        outputs: list of `ctx.actions.declare_file`
        build_command: the command to build `outputs` and `implicit_outputs`
        modules_staging_dir: a staging directory for module installation
        implicit_outputs: like `outputs`, but not installed to `DIST_DIR` (not returned in
          `DefaultInfo`)
    """
    kernel_build = ctx.attr.kernel_modules_install[KernelModuleInfo].kernel_build
    kernel_build_outs = kernel_build[KernelBuildInfo].outs + kernel_build[KernelBuildInfo].base_kernel_files
    system_map = find_file(
        name = "System.map",
        files = kernel_build_outs,
        required = True,
        what = "{}: outs of dependent kernel_build {}".format(ctx.label, kernel_build),
    )
    modules_install_staging_dws = ctx.attr.kernel_modules_install[KernelModuleInfo].modules_staging_dws

    inputs = []
    if additional_inputs != None:
        inputs += additional_inputs
    inputs += [
        system_map,
    ]
    inputs += dws.files(modules_install_staging_dws)
    inputs += ctx.files.deps
    inputs += kernel_build[KernelEnvInfo].dependencies

    command_outputs = []
    command_outputs += outputs
    if implicit_outputs != None:
        command_outputs += implicit_outputs

    command = ""
    command += kernel_build[KernelEnvInfo].setup

    for attr_name in (
        "modules_list",
        "modules_blocklist",
        "modules_options",
        "vendor_dlkm_modules_list",
        "vendor_dlkm_modules_blocklist",
        "vendor_dlkm_props",
    ):
        # Checks if attr_name is a valid attribute name in the current rule.
        # If not, do not touch its value.
        if not hasattr(ctx.file, attr_name):
            continue

        # If it is a valid attribute name, set environment variable to the path if the argument is
        # supplied, otherwise set environment variable to empty.
        file = getattr(ctx.file, attr_name)
        path = ""
        if file != None:
            path = file.path
            inputs.append(file)
        command += """
            {name}={path}
        """.format(
            name = attr_name.upper(),
            path = path,
        )

    # Allow writing to files because create_modules_staging wants to overwrite modules.order.
    command += dws.restore(
        modules_install_staging_dws,
        dst = modules_staging_dir,
        options = "-aL --chmod=F+w",
    )

    command += """
             # Restore System.map to DIST_DIR for run_depmod in create_modules_staging
               mkdir -p ${{DIST_DIR}}
               cp {system_map} ${{DIST_DIR}}/System.map

               {build_command}
    """.format(
        system_map = system_map.path,
        build_command = build_command,
    )

    debug.print_scripts(ctx, command)
    ctx.actions.run_shell(
        mnemonic = mnemonic,
        inputs = inputs,
        outputs = command_outputs,
        progress_message = "Building {} {}".format(what, ctx.label),
        command = command,
    )
    return DefaultInfo(files = depset(outputs))

def _build_modules_image_attrs_common(additional = None):
    """Common attrs for rules that builds images that directly contain modules."""
    ret = {
        "kernel_modules_install": attr.label(
            mandatory = True,
            providers = [KernelModuleInfo],
        ),
        "deps": attr.label_list(
            allow_files = True,
        ),
        "_debug_print_scripts": attr.label(
            default = "//build/kernel/kleaf:debug_print_scripts",
        ),
    }
    if additional != None:
        ret.update(additional)
    return ret

_InitramfsInfo = provider(fields = {
    "initramfs_img": "Output image",
    "initramfs_staging_archive": "Archive of initramfs staging directory",
})

def _initramfs_impl(ctx):
    initramfs_img = ctx.actions.declare_file("{}/initramfs.img".format(ctx.label.name))
    modules_load = ctx.actions.declare_file("{}/modules.load".format(ctx.label.name))
    vendor_boot_modules_load = ctx.outputs.vendor_boot_modules_load
    initramfs_staging_archive = ctx.actions.declare_file("{}/initramfs_staging_archive.tar.gz".format(ctx.label.name))

    outputs = [
        initramfs_img,
        modules_load,
        vendor_boot_modules_load,
    ]

    modules_staging_dir = initramfs_img.dirname + "/staging"
    initramfs_staging_dir = modules_staging_dir + "/initramfs_staging"

    command = """
               mkdir -p {initramfs_staging_dir}
             # Build initramfs
               create_modules_staging "${{MODULES_LIST}}" {modules_staging_dir} \
                 {initramfs_staging_dir} "${{MODULES_BLOCKLIST}}" "-e"
               modules_root_dir=$(echo {initramfs_staging_dir}/lib/modules/*)
               cp ${{modules_root_dir}}/modules.load {modules_load}
               cp ${{modules_root_dir}}/modules.load {vendor_boot_modules_load}
               echo "${{MODULES_OPTIONS}}" > ${{modules_root_dir}}/modules.options
               mkbootfs "{initramfs_staging_dir}" >"{modules_staging_dir}/initramfs.cpio"
               ${{RAMDISK_COMPRESS}} "{modules_staging_dir}/initramfs.cpio" >"{initramfs_img}"
             # Archive initramfs_staging_dir
               tar czf {initramfs_staging_archive} -C {initramfs_staging_dir} .
             # Remove staging directories
               rm -rf {initramfs_staging_dir}
    """.format(
        modules_staging_dir = modules_staging_dir,
        initramfs_staging_dir = initramfs_staging_dir,
        modules_load = modules_load.path,
        vendor_boot_modules_load = vendor_boot_modules_load.path,
        initramfs_img = initramfs_img.path,
        initramfs_staging_archive = initramfs_staging_archive.path,
    )

    default_info = _build_modules_image_impl_common(
        ctx = ctx,
        what = "initramfs",
        outputs = outputs,
        build_command = command,
        modules_staging_dir = modules_staging_dir,
        implicit_outputs = [
            initramfs_staging_archive,
        ],
        mnemonic = "Initramfs",
    )
    return [
        default_info,
        _InitramfsInfo(
            initramfs_img = initramfs_img,
            initramfs_staging_archive = initramfs_staging_archive,
        ),
    ]

_initramfs = rule(
    implementation = _initramfs_impl,
    doc = """Build initramfs.

When included in a `copy_to_dist_dir` rule, this rule copies the following to `DIST_DIR`:
- `initramfs.img`
- `modules.load`
- `vendor_boot.modules.load`

An additional label, `{name}/vendor_boot.modules.load`, is declared to point to the
corresponding files.
""",
    attrs = _build_modules_image_attrs_common({
        "vendor_boot_modules_load": attr.output(),
        "modules_list": attr.label(allow_single_file = True),
        "modules_blocklist": attr.label(allow_single_file = True),
        "modules_options": attr.label(allow_single_file = True),
    }),
)

def _system_dlkm_image_impl(ctx):
    system_dlkm_img = ctx.actions.declare_file("{}/system_dlkm.img".format(ctx.label.name))
    system_dlkm_staging_archive = ctx.actions.declare_file("{}/system_dlkm_staging_archive.tar.gz".format(ctx.label.name))

    modules_staging_dir = system_dlkm_img.dirname + "/staging"
    system_dlkm_staging_dir = modules_staging_dir + "/system_dlkm_staging"

    command = """
               mkdir -p {system_dlkm_staging_dir}
             # Build system_dlkm.img
               create_modules_staging "${{MODULES_LIST}}" {modules_staging_dir} \
                 {system_dlkm_staging_dir} "${{MODULES_BLOCKLIST}}" "-e"
               modules_root_dir=$(ls {system_dlkm_staging_dir}/lib/modules/*)
             # Re-sign the stripped modules using kernel build time key
               for module in $(find {system_dlkm_staging_dir} -type f -name '*.ko'); do
                   "${{OUT_DIR}}"/scripts/sign-file sha1 \
                   "${{OUT_DIR}}"/certs/signing_key.pem \
                   "${{OUT_DIR}}"/certs/signing_key.x509 "${{module}}"
               done
             # Build system_dlkm.img with signed GKI modules
               mkfs.erofs -zlz4hc "{system_dlkm_img}" "{system_dlkm_staging_dir}"
             # No need to sign the image as modules are signed; add hash footer
               avbtool add_hashtree_footer \
                   --partition_name system_dlkm \
                   --image "{system_dlkm_img}"
             # Archive system_dlkm_staging_dir
               tar czf {system_dlkm_staging_archive} -C {system_dlkm_staging_dir} .
             # Remove staging directories
               rm -rf {system_dlkm_staging_dir}
    """.format(
        modules_staging_dir = modules_staging_dir,
        system_dlkm_staging_dir = system_dlkm_staging_dir,
        system_dlkm_img = system_dlkm_img.path,
        system_dlkm_staging_archive = system_dlkm_staging_archive.path,
    )

    default_info = _build_modules_image_impl_common(
        ctx = ctx,
        what = "system_dlkm",
        outputs = [system_dlkm_img, system_dlkm_staging_archive],
        build_command = command,
        modules_staging_dir = modules_staging_dir,
        mnemonic = "SystemDlkmImage",
    )
    return [default_info]

_system_dlkm_image = rule(
    implementation = _system_dlkm_image_impl,
    doc = """Build system_dlkm.img an erofs image with GKI modules.

When included in a `copy_to_dist_dir` rule, this rule copies the `system_dlkm.img` to `DIST_DIR`.

""",
    attrs = _build_modules_image_attrs_common({
        "modules_list": attr.label(allow_single_file = True),
        "modules_blocklist": attr.label(allow_single_file = True),
    }),
)

def _vendor_dlkm_image_impl(ctx):
    vendor_dlkm_img = ctx.actions.declare_file("{}/vendor_dlkm.img".format(ctx.label.name))
    vendor_dlkm_modules_load = ctx.actions.declare_file("{}/vendor_dlkm.modules.load".format(ctx.label.name))
    vendor_dlkm_modules_blocklist = ctx.actions.declare_file("{}/vendor_dlkm.modules.blocklist".format(ctx.label.name))
    modules_staging_dir = vendor_dlkm_img.dirname + "/staging"
    vendor_dlkm_staging_dir = modules_staging_dir + "/vendor_dlkm_staging"

    command = ""
    additional_inputs = []
    if ctx.file.vendor_boot_modules_load:
        command += """
                # Restore vendor_boot.modules.load
                  cp {vendor_boot_modules_load} ${{DIST_DIR}}/vendor_boot.modules.load
        """.format(
            vendor_boot_modules_load = ctx.file.vendor_boot_modules_load.path,
        )
        additional_inputs.append(ctx.file.vendor_boot_modules_load)

    command += """
            # Build vendor_dlkm
              mkdir -p {vendor_dlkm_staging_dir}
              (
                MODULES_STAGING_DIR={modules_staging_dir}
                VENDOR_DLKM_STAGING_DIR={vendor_dlkm_staging_dir}
                build_vendor_dlkm
              )
            # Move output files into place
              mv "${{DIST_DIR}}/vendor_dlkm.img" {vendor_dlkm_img}
              mv "${{DIST_DIR}}/vendor_dlkm.modules.load" {vendor_dlkm_modules_load}
              if [[ -f "${{DIST_DIR}}/vendor_dlkm.modules.blocklist" ]]; then
                mv "${{DIST_DIR}}/vendor_dlkm.modules.blocklist" {vendor_dlkm_modules_blocklist}
              else
                : > {vendor_dlkm_modules_blocklist}
              fi
            # Remove staging directories
              rm -rf {vendor_dlkm_staging_dir}
    """.format(
        modules_staging_dir = modules_staging_dir,
        vendor_dlkm_staging_dir = vendor_dlkm_staging_dir,
        vendor_dlkm_img = vendor_dlkm_img.path,
        vendor_dlkm_modules_load = vendor_dlkm_modules_load.path,
        vendor_dlkm_modules_blocklist = vendor_dlkm_modules_blocklist.path,
    )

    return _build_modules_image_impl_common(
        ctx = ctx,
        what = "vendor_dlkm",
        outputs = [vendor_dlkm_img, vendor_dlkm_modules_load, vendor_dlkm_modules_blocklist],
        build_command = command,
        modules_staging_dir = modules_staging_dir,
        additional_inputs = additional_inputs,
        mnemonic = "VendorDlkmImage",
    )

_vendor_dlkm_image = rule(
    implementation = _vendor_dlkm_image_impl,
    doc = """Build vendor_dlkm image.

Execute `build_vendor_dlkm` in `build_utils.sh`.

When included in a `copy_to_dist_dir` rule, this rule copies a `vendor_dlkm.img` to `DIST_DIR`.
""",
    attrs = _build_modules_image_attrs_common({
        "vendor_boot_modules_load": attr.label(
            allow_single_file = True,
            doc = """File to `vendor_boot.modules.load`.

Modules listed in this file is stripped away from the `vendor_dlkm` image.""",
        ),
        "vendor_dlkm_modules_list": attr.label(allow_single_file = True),
        "vendor_dlkm_modules_blocklist": attr.label(allow_single_file = True),
        "vendor_dlkm_props": attr.label(allow_single_file = True),
    }),
)

def _boot_images_impl(ctx):
    outdir = ctx.actions.declare_directory(ctx.label.name)
    modules_staging_dir = outdir.path + "/staging"
    mkbootimg_staging_dir = modules_staging_dir + "/mkbootimg_staging"

    if ctx.attr.initramfs:
        initramfs_staging_archive = ctx.attr.initramfs[_InitramfsInfo].initramfs_staging_archive
        initramfs_staging_dir = modules_staging_dir + "/initramfs_staging"

    outs = []
    for out in ctx.outputs.outs:
        outs.append(out.short_path[len(outdir.short_path) + 1:])

    kernel_build_outs = ctx.attr.kernel_build[KernelBuildInfo].outs + ctx.attr.kernel_build[KernelBuildInfo].base_kernel_files

    inputs = [
        ctx.file.mkbootimg,
        ctx.file._search_and_cp_output,
    ]
    if ctx.attr.initramfs:
        inputs += [
            ctx.attr.initramfs[_InitramfsInfo].initramfs_img,
            initramfs_staging_archive,
        ]
    inputs += ctx.files.deps
    inputs += ctx.attr.kernel_build[KernelEnvInfo].dependencies
    inputs += kernel_build_outs
    inputs += ctx.files.vendor_ramdisk_binaries

    command = ""
    command += ctx.attr.kernel_build[KernelEnvInfo].setup

    if ctx.attr.build_boot:
        boot_flag_cmd = "BUILD_BOOT_IMG=1"
    else:
        boot_flag_cmd = "BUILD_BOOT_IMG="

    if not ctx.attr.vendor_boot_name:
        vendor_boot_flag_cmd = """
            BUILD_VENDOR_BOOT_IMG=
            SKIP_VENDOR_BOOT=1
            BUILD_VENDOR_KERNEL_BOOT=
        """
    elif ctx.attr.vendor_boot_name == "vendor_boot":
        vendor_boot_flag_cmd = """
            BUILD_VENDOR_BOOT_IMG=1
            SKIP_VENDOR_BOOT=
            BUILD_VENDOR_KERNEL_BOOT=
        """
    elif ctx.attr.vendor_boot_name == "vendor_kernel_boot":
        vendor_boot_flag_cmd = """
            BUILD_VENDOR_BOOT_IMG=1
            SKIP_VENDOR_BOOT=
            BUILD_VENDOR_KERNEL_BOOT=1
        """
    else:
        fail("{}: unknown vendor_boot_name {}".format(ctx.label, ctx.attr.vendor_boot_name))

    if ctx.files.vendor_ramdisk_binaries:
        # build_utils.sh uses singular VENDOR_RAMDISK_BINARY
        command += """
            VENDOR_RAMDISK_BINARY="{vendor_ramdisk_binaries}"
        """.format(
            vendor_ramdisk_binaries = " ".join([file.path for file in ctx.files.vendor_ramdisk_binaries]),
        )

    command += """
             # Create and restore DIST_DIR.
             # We don't need all of *_for_dist. Copying all declared outputs of kernel_build is
             # sufficient.
               mkdir -p ${{DIST_DIR}}
               cp {kernel_build_outs} ${{DIST_DIR}}
    """.format(
        kernel_build_outs = " ".join([out.path for out in kernel_build_outs]),
    )

    if ctx.attr.initramfs:
        command += """
               cp {initramfs_img} ${{DIST_DIR}}/initramfs.img
             # Create and restore initramfs_staging_dir
               mkdir -p {initramfs_staging_dir}
               tar xf {initramfs_staging_archive} -C {initramfs_staging_dir}
        """.format(
            initramfs_img = ctx.attr.initramfs[_InitramfsInfo].initramfs_img.path,
            initramfs_staging_dir = initramfs_staging_dir,
            initramfs_staging_archive = initramfs_staging_archive.path,
        )
        set_initramfs_var_cmd = """
               BUILD_INITRAMFS=1
               INITRAMFS_STAGING_DIR={initramfs_staging_dir}
        """.format(
            initramfs_staging_dir = initramfs_staging_dir,
        )
    else:
        set_initramfs_var_cmd = """
               BUILD_INITRAMFS=
               INITRAMFS_STAGING_DIR=
        """

    command += """
             # Build boot images
               (
                 {boot_flag_cmd}
                 {vendor_boot_flag_cmd}
                 {set_initramfs_var_cmd}
                 MKBOOTIMG_STAGING_DIR=$(readlink -m {mkbootimg_staging_dir})
                 build_boot_images
               )
               {search_and_cp_output} --srcdir ${{DIST_DIR}} --dstdir {outdir} {outs}
             # Remove staging directories
               rm -rf {modules_staging_dir}
    """.format(
        mkbootimg_staging_dir = mkbootimg_staging_dir,
        search_and_cp_output = ctx.file._search_and_cp_output.path,
        outdir = outdir.path,
        outs = " ".join(outs),
        modules_staging_dir = modules_staging_dir,
        boot_flag_cmd = boot_flag_cmd,
        vendor_boot_flag_cmd = vendor_boot_flag_cmd,
        set_initramfs_var_cmd = set_initramfs_var_cmd,
    )

    debug.print_scripts(ctx, command)
    ctx.actions.run_shell(
        mnemonic = "BootImages",
        inputs = inputs,
        outputs = ctx.outputs.outs + [outdir],
        progress_message = "Building boot images {}".format(ctx.label),
        command = command,
    )

_boot_images = rule(
    implementation = _boot_images_impl,
    doc = """Build boot images, including `boot.img`, `vendor_boot.img`, etc.

Execute `build_boot_images` in `build_utils.sh`.""",
    attrs = {
        "kernel_build": attr.label(
            mandatory = True,
            providers = [KernelEnvInfo, KernelBuildInfo],
        ),
        "initramfs": attr.label(
            providers = [_InitramfsInfo],
        ),
        "deps": attr.label_list(
            allow_files = True,
        ),
        "outs": attr.output_list(),
        "mkbootimg": attr.label(
            allow_single_file = True,
            default = "//tools/mkbootimg:mkbootimg.py",
        ),
        "build_boot": attr.bool(),
        "vendor_boot_name": attr.string(doc = """
* If `"vendor_boot"`, build `vendor_boot.img`
* If `"vendor_kernel_boot"`, build `vendor_kernel_boot.img`
* If `None`, skip `vendor_boot`.
""", values = ["vendor_boot", "vendor_kernel_boot"]),
        "vendor_ramdisk_binaries": attr.label_list(allow_files = True),
        "_debug_print_scripts": attr.label(
            default = "//build/kernel/kleaf:debug_print_scripts",
        ),
        "_search_and_cp_output": attr.label(
            allow_single_file = True,
            default = Label("//build/kernel/kleaf:search_and_cp_output.py"),
        ),
    },
)

def _dtbo_impl(ctx):
    output = ctx.actions.declare_file("{}/dtbo.img".format(ctx.label.name))
    inputs = []
    inputs += ctx.attr.kernel_build[KernelEnvInfo].dependencies
    inputs += ctx.files.srcs
    command = ""
    command += ctx.attr.kernel_build[KernelEnvInfo].setup

    command += """
             # make dtbo
               mkdtimg create {output} ${{MKDTIMG_FLAGS}} {srcs}
    """.format(
        output = output.path,
        srcs = " ".join([f.path for f in ctx.files.srcs]),
    )

    debug.print_scripts(ctx, command)
    ctx.actions.run_shell(
        mnemonic = "Dtbo",
        inputs = inputs,
        outputs = [output],
        progress_message = "Building dtbo {}".format(ctx.label),
        command = command,
    )
    return DefaultInfo(files = depset([output]))

_dtbo = rule(
    implementation = _dtbo_impl,
    doc = "Build dtbo.",
    attrs = {
        "kernel_build": attr.label(
            mandatory = True,
            providers = [KernelEnvInfo, KernelBuildInfo],
        ),
        "srcs": attr.label_list(
            allow_files = True,
        ),
        "_debug_print_scripts": attr.label(
            default = "//build/kernel/kleaf:debug_print_scripts",
        ),
    },
)

def kernel_images(
        name,
        kernel_modules_install,
        kernel_build = None,
        build_initramfs = None,
        build_vendor_dlkm = None,
        build_boot = None,
        build_vendor_boot = None,
        build_vendor_kernel_boot = None,
        build_system_dlkm = None,
        build_dtbo = None,
        dtbo_srcs = None,
        mkbootimg = None,
        deps = None,
        boot_image_outs = None,
        modules_list = None,
        modules_blocklist = None,
        modules_options = None,
        vendor_ramdisk_binaries = None,
        vendor_dlkm_modules_list = None,
        vendor_dlkm_modules_blocklist = None,
        vendor_dlkm_props = None):
    """Build multiple kernel images.

    Args:
        name: name of this rule, e.g. `kernel_images`,
        kernel_modules_install: A `kernel_modules_install` rule.

          The main kernel build is inferred from the `kernel_build` attribute of the
          specified `kernel_modules_install` rule. The main kernel build must contain
          `System.map` in `outs` (which is included if you use `aarch64_outs` or
          `x86_64_outs` from `common_kernels.bzl`).
        kernel_build: A `kernel_build` rule. Must specify if `build_boot`.
        mkbootimg: Path to the mkbootimg.py script which builds boot.img.
          Keep in sync with `MKBOOTIMG_PATH`. Only used if `build_boot`. If `None`,
          default to `//tools/mkbootimg:mkbootimg.py`.
        deps: Additional dependencies to build images.

          This must include the following:
          - For `initramfs`:
            - The file specified by `MODULES_LIST`
            - The file specified by `MODULES_BLOCKLIST`, if `MODULES_BLOCKLIST` is set
          - For `vendor_dlkm` image:
            - The file specified by `VENDOR_DLKM_MODULES_LIST`
            - The file specified by `VENDOR_DLKM_MODULES_BLOCKLIST`, if set
            - The file specified by `VENDOR_DLKM_PROPS`, if set
            - The file specified by `selinux_fc` in `VENDOR_DLKM_PROPS`, if set

        boot_image_outs: A list of output files that will be installed to `DIST_DIR` when
          `build_boot_images` in `build/kernel/build_utils.sh` is executed.

          You may leave out `vendor_boot.img` from the list. It is automatically added when
          `build_vendor_boot = True`.

          If `build_boot` is equal to `False`, the default is empty.

          If `build_boot` is equal to `True`, the default list assumes the following:
          - `BOOT_IMAGE_FILENAME` is not set (which takes default value `boot.img`), or is set to
            `"boot.img"`
          - `vendor_boot.img` if `build_vendor_boot`
          - `RAMDISK_EXT=lz4`. If the build configuration has a different value, replace
            `ramdisk.lz4` with `ramdisk.{RAMDISK_EXT}` accordingly.
          - `BOOT_IMAGE_HEADER_VERSION >= 4`, which creates `vendor-bootconfig.img` to contain
            `VENDOR_BOOTCONFIG`
          - The list contains `dtb.img`
        build_initramfs: Whether to build initramfs. Keep in sync with `BUILD_INITRAMFS`.
        build_system_dlkm: Whether to build system_dlkm.img an erofs image with GKI modules.
        build_vendor_dlkm: Whether to build `vendor_dlkm` image. It must be set if
          `vendor_dlkm_modules_list` is set.

          Note: at the time of writing (Jan 2022), unlike `build.sh`,
          `vendor_dlkm.modules.blocklist` is **always** created
          regardless of the value of `VENDOR_DLKM_MODULES_BLOCKLIST`.
          If `build_vendor_dlkm()` in `build_utils.sh` does not generate
          `vendor_dlkm.modules.blocklist`, an empty file is created.
        build_boot: Whether to build boot image. It must be set if either `BUILD_BOOT_IMG`
          or `BUILD_VENDOR_BOOT_IMG` is set.

          This depends on `initramfs` and `kernel_build`. Hence, if this is set to `True`,
          `build_initramfs` is implicitly true, and `kernel_build` must be set.

          If `True`, adds `boot.img` to `boot_image_outs` if not already in the list.
        build_vendor_boot: Whether to build `vendor_boot.img`. It must be set if either
          `BUILD_BOOT_IMG` or `BUILD_VENDOR_BOOT_IMG` is set, and `SKIP_VENDOR_BOOT` is not set,
          and `BUILD_VENDOR_KERNEL_BOOT` is not set.

          At most **one** of `build_vendor_boot` and `build_vendor_kernel_boot` may be set to
          `True`.

          If `True`, adds `vendor_boot.img` to `boot_image_outs` if not already in the list.

        build_vendor_kernel_boot: Whether to build `vendor_kernel_boot.img`. It must be set if either
          `BUILD_BOOT_IMG` or `BUILD_VENDOR_BOOT_IMG` is set, and `SKIP_VENDOR_BOOT` is not set,
          and `BUILD_VENDOR_KERNEL_BOOT` is set.

          At most **one** of `build_vendor_boot` and `build_vendor_kernel_boot` may be set to
          `True`.

          If `True`, adds `vendor_kernel_boot.img` to `boot_image_outs` if not already in the list.
        build_dtbo: Whether to build dtbo image. Keep this in sync with `BUILD_DTBO_IMG`.

          If `dtbo_srcs` is non-empty, `build_dtbo` is `True` by default. Otherwise it is `False`
          by default.
        dtbo_srcs: list of `*.dtbo` files used to package the `dtbo.img`. Keep this in sync
          with `MKDTIMG_DTBOS`; see example below.

          If `dtbo_srcs` is non-empty, `build_dtbo` must not be explicitly set to `False`.

          Example:
          ```
          kernel_build(
              name = "tuna_kernel",
              outs = [
                  "path/to/foo.dtbo",
                  "path/to/bar.dtbo",
              ],
          )
          kernel_images(
              name = "tuna_images",
              kernel_build = ":tuna_kernel",
              dtbo_srcs = [
                  ":tuna_kernel/path/to/foo.dtbo",
                  ":tuna_kernel/path/to/bar.dtbo",
              ]
          )
          ```
        modules_list: A file containing list of modules to use for `vendor_boot.modules.load`.

          This corresponds to `MODULES_LIST` in `build.config` for `build.sh`.
        modules_blocklist: A file containing a list of modules which are
          blocked from being loaded.

          This file is copied directly to staging directory, and should be in the format:
          ```
          blocklist module_name
          ```

          This corresponds to `MODULES_BLOCKLIST` in `build.config` for `build.sh`.
        modules_options: A `/lib/modules/modules.options` file is created on the ramdisk containing
          the contents of this variable.

          Lines should be of the form:
          ```
          options <modulename> <param1>=<val> <param2>=<val> ...
          ```

          This corresponds to `MODULES_OPTIONS` in `build.config` for `build.sh`.
        vendor_dlkm_modules_list: location of an optional file
          containing the list of kernel modules which shall be copied into a
          `vendor_dlkm` partition image. Any modules passed into `MODULES_LIST` which
          become part of the `vendor_boot.modules.load` will be trimmed from the
          `vendor_dlkm.modules.load`.

          This corresponds to `VENDOR_DLKM_MODULES_LIST` in `build.config` for `build.sh`.
        vendor_dlkm_modules_blocklist: location of an optional file containing a list of modules
          which are blocked from being loaded.

          This file is copied directly to the staging directory and should be in the format:
          ```
          blocklist module_name
          ```

          This corresponds to `VENDOR_DLKM_MODULES_BLOCKLIST` in `build.config` for `build.sh`.
        vendor_dlkm_props: location of a text file containing
          the properties to be used for creation of a `vendor_dlkm` image
          (filesystem, partition size, etc). If this is not set (and
          `build_vendor_dlkm` is), a default set of properties will be used
          which assumes an ext4 filesystem and a dynamic partition.

          This corresponds to `VENDOR_DLKM_PROPS` in `build.config` for `build.sh`.
        vendor_ramdisk_binaries: List of vendor ramdisk binaries
          which includes the device-specific components of ramdisk like the fstab
          file and the device-specific rc files. If specifying multiple vendor ramdisks
          and identical file paths exist in the ramdisks, the file from last ramdisk is used.

          Note: **order matters**. To prevent buildifier from sorting the list, add the following:
          ```
          # do not sort
          ```

          This corresponds to `VENDOR_RAMDISK_BINARY` in `build.config` for `build.sh`.
    """
    all_rules = []

    build_any_boot_image = build_boot or build_vendor_boot or build_vendor_kernel_boot
    if build_any_boot_image:
        if kernel_build == None:
            fail("{}: Must set kernel_build if any of these are true: build_boot={}, build_vendor_boot={}, build_vendor_kernel_boot={}".format(name, build_boot, build_vendor_boot, build_vendor_kernel_boot))

    # Set default value for boot_image_outs according to build_boot
    if boot_image_outs == None:
        if not build_any_boot_image:
            boot_image_outs = []
        else:
            boot_image_outs = [
                "dtb.img",
                "ramdisk.lz4",
                "vendor-bootconfig.img",
            ]

    boot_image_outs = list(boot_image_outs)

    if build_boot and "boot.img" not in boot_image_outs:
        boot_image_outs.append("boot.img")

    if build_vendor_boot and "vendor_boot.img" not in boot_image_outs:
        boot_image_outs.append("vendor_boot.img")

    if build_vendor_kernel_boot and "vendor_kernel_boot.img" not in boot_image_outs:
        boot_image_outs.append("vendor_kernel_boot.img")

    if build_initramfs:
        _initramfs(
            name = "{}_initramfs".format(name),
            kernel_modules_install = kernel_modules_install,
            deps = deps,
            vendor_boot_modules_load = "{}_initramfs/vendor_boot.modules.load".format(name),
            modules_list = modules_list,
            modules_blocklist = modules_blocklist,
            modules_options = modules_options,
        )
        all_rules.append(":{}_initramfs".format(name))

    if build_system_dlkm:
        _system_dlkm_image(
            name = "{}_system_dlkm_image".format(name),
            kernel_modules_install = kernel_modules_install,
            deps = deps,
            modules_list = modules_list,
            modules_blocklist = modules_blocklist,
        )
        all_rules.append(":{}_system_dlkm_image".format(name))

    if build_vendor_dlkm:
        _vendor_dlkm_image(
            name = "{}_vendor_dlkm_image".format(name),
            kernel_modules_install = kernel_modules_install,
            vendor_boot_modules_load = "{}_initramfs/vendor_boot.modules.load".format(name) if build_initramfs else None,
            deps = deps,
            vendor_dlkm_modules_list = vendor_dlkm_modules_list,
            vendor_dlkm_modules_blocklist = vendor_dlkm_modules_blocklist,
            vendor_dlkm_props = vendor_dlkm_props,
        )
        all_rules.append(":{}_vendor_dlkm_image".format(name))

    if build_any_boot_image:
        if build_vendor_kernel_boot:
            vendor_boot_name = "vendor_kernel_boot"
        elif build_vendor_boot:
            vendor_boot_name = "vendor_boot"
        else:
            vendor_boot_name = None
        _boot_images(
            name = "{}_boot_images".format(name),
            kernel_build = kernel_build,
            outs = ["{}_boot_images/{}".format(name, out) for out in boot_image_outs],
            deps = deps,
            initramfs = ":{}_initramfs".format(name) if build_initramfs else None,
            mkbootimg = mkbootimg,
            vendor_ramdisk_binaries = vendor_ramdisk_binaries,
            build_boot = build_boot,
            vendor_boot_name = vendor_boot_name,
        )
        all_rules.append(":{}_boot_images".format(name))

    if build_dtbo == None:
        build_dtbo = bool(dtbo_srcs)

    if dtbo_srcs:
        if not build_dtbo:
            fail("{}: build_dtbo must be True if dtbo_srcs is non-empty.")

    if build_dtbo:
        _dtbo(
            name = "{}_dtbo".format(name),
            srcs = dtbo_srcs,
            kernel_build = kernel_build,
        )
        all_rules.append(":{}_dtbo".format(name))

    native.filegroup(
        name = name,
        srcs = all_rules,
    )

def _kernel_filegroup_impl(ctx):
    all_deps = ctx.files.srcs + ctx.files.deps

    # TODO(b/219112010): implement KernelEnvInfo for the modules_prepare target
    modules_prepare_out_dir_tar_gz = find_file("modules_prepare_outdir.tar.gz", all_deps, what = ctx.label)
    modules_prepare_setup = """
         # Restore modules_prepare outputs. Assumes env setup.
           [ -z ${{OUT_DIR}} ] && echo "ERROR: modules_prepare setup run without OUT_DIR set!" >&2 && exit 1
           tar xf {outdir_tar_gz} -C ${{OUT_DIR}}
    """.format(outdir_tar_gz = modules_prepare_out_dir_tar_gz)
    modules_prepare_deps = [modules_prepare_out_dir_tar_gz]

    kernel_module_dev_info = KernelBuildExtModuleInfo(
        modules_staging_archive = find_file("modules_staging_dir.tar.gz", all_deps, what = ctx.label),
        modules_prepare_setup = modules_prepare_setup,
        modules_prepare_deps = modules_prepare_deps,
        # TODO(b/211515836): module_srcs might also be downloaded
        module_srcs = kernel_utils.filter_module_srcs(ctx.files.kernel_srcs),
        collect_unstripped_modules = ctx.attr.collect_unstripped_modules,
    )
    uapi_info = KernelBuildUapiInfo(
        kernel_uapi_headers = ctx.attr.kernel_uapi_headers,
    )

    unstripped_modules_info = None
    for target in ctx.attr.srcs:
        if KernelUnstrippedModulesInfo in target:
            unstripped_modules_info = target[KernelUnstrippedModulesInfo]
            break
    if unstripped_modules_info == None:
        # Reverse of kernel_unstripped_modules_archive
        unstripped_modules_archive = find_file("unstripped_modules.tar.gz", all_deps, what = ctx.label, required = True)
        unstripped_dir = ctx.actions.declare_directory("{}/unstripped".format(ctx.label.name))
        command = ctx.attr._hermetic_tools[HermeticToolsInfo].setup + """
            tar xf {unstripped_modules_archive} -C $(dirname {unstripped_dir}) $(basename {unstripped_dir})
        """
        debug.print_scripts(ctx, command, what = "unstripped_modules_archive")
        ctx.actions.run_shell(
            command = command,
            inputs = ctx.attr._hermetic_tools[HermeticToolsInfo].deps + [
                unstripped_modules_archive,
            ],
            outputs = [unstripped_dir],
            progress_message = "Extracting unstripped_modules_archive {}".format(ctx.label),
            mnemonic = "KernelFilegroupUnstrippedModulesArchive",
        )
        unstripped_modules_info = KernelUnstrippedModulesInfo(directory = unstripped_dir)

    abi_info = KernelBuildAbiInfo(module_outs_file = ctx.file.module_outs_file)
    base_kernel_info = KernelBuildInTreeModulesInfo(module_outs_file = ctx.file.module_outs_file)

    return [
        DefaultInfo(files = depset(ctx.files.srcs)),
        kernel_module_dev_info,
        # TODO(b/219112010): implement KernelEnvInfo for kernel_filegroup
        uapi_info,
        unstripped_modules_info,
        abi_info,
        base_kernel_info,
    ]

kernel_filegroup = rule(
    implementation = _kernel_filegroup_impl,
    doc = """Specify a list of kernel prebuilts.

This is similar to [`filegroup`](https://docs.bazel.build/versions/main/be/general.html#filegroup)
that gives a convenient name to a collection of targets, which can be referenced from other rules.

It can be used in the `base_kernel` attribute of a [`kernel_build`](#kernel_build).
""",
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            doc = """The list of labels that are members of this file group.

This usually contains a list of prebuilts, e.g. `vmlinux`, `Image.lz4`, `kernel-headers.tar.gz`,
etc.

Not to be confused with [`kernel_srcs`](#kernel_filegroup-kernel_srcs).""",
        ),
        "deps": attr.label_list(
            allow_files = True,
            doc = """A list of additional labels that participates in implementing the providers.

This usually contains a list of prebuilts.

Unlike srcs, these labels are NOT added to the [`DefaultInfo`](https://docs.bazel.build/versions/main/skylark/lib/DefaultInfo.html)""",
        ),
        "kernel_srcs": attr.label_list(
            allow_files = True,
            doc = """A list of files that would have been listed as `srcs` if this rule were a [`kernel_build`](#kernel_build).

This is usually a `glob()` of source files.

Not to be confused with [`srcs`](#kernel_filegroup-srcs).
""",
        ),
        "kernel_uapi_headers": attr.label(
            allow_files = True,
            doc = """The label pointing to `kernel-uapi-headers.tar.gz`.

This attribute should be set to the `kernel-uapi-headers.tar.gz` artifact built by the
[`kernel_build`](#kernel_build) macro if the `kernel_filegroup` rule were a `kernel_build`.

Setting this attribute allows [`merged_kernel_uapi_headers`](#merged_kernel_uapi_headers) to
work properly when this `kernel_filegroup` is set to the `base_kernel`.

For example:
```
kernel_filegroup(
    name = "kernel_aarch64_prebuilts",
    srcs = [
        "vmlinux",
        # ...
    ],
    kernel_uapi_headers = "kernel-uapi-headers.tar.gz",
)

kernel_build(
    name = "tuna",
    base_kernel = ":kernel_aarch64_prebuilts",
    # ...
)

merged_kernel_uapi_headers(
    name = "tuna_merged_kernel_uapi_headers",
    kernel_build = "tuna",
    # ...
)
```
""",
        ),
        "collect_unstripped_modules": attr.bool(
            default = True,
            doc = """See [`kernel_build.collect_unstripped_modules`](#kernel_build-collect_unstripped_modules).

Unlike `kernel_build`, this has default value `True` because
[`kernel_build_abi`](#kernel_build_abi) sets
[`define_abi_targets`](#kernel_build_abi-define_abi_targets) to `True` by
default, which in turn sets `collect_unstripped_modules` to `True` by default.
""",
        ),
        "module_outs_file": attr.label(
            allow_single_file = True,
            doc = """A file containing `module_outs` of the original [`kernel_build`](#kernel_build) target.""",
        ),
        "_hermetic_tools": attr.label(default = "//build/kernel:hermetic-tools", providers = [HermeticToolsInfo]),
    },
)

def _kernel_compile_commands_impl(ctx):
    interceptor_output = ctx.attr.kernel_build[KernelBuildInfo].interceptor_output
    if not interceptor_output:
        fail("{}: kernel_build {} does not have enable_interceptor = True.".format(ctx.label, ctx.attr.kernel_build.label))
    compile_commands = ctx.actions.declare_file(ctx.attr.name + "/compile_commands.json")
    inputs = [interceptor_output]
    inputs += ctx.attr.kernel_build[KernelEnvInfo].dependencies
    command = ctx.attr.kernel_build[KernelEnvInfo].setup
    command += """
             # Generate compile_commands.json
               interceptor_analysis -l {interceptor_output} -o {compile_commands} -t compdb_commands --relative
    """.format(
        interceptor_output = interceptor_output.path,
        compile_commands = compile_commands.path,
    )
    ctx.actions.run_shell(
        mnemonic = "KernelCompileCommands",
        inputs = inputs,
        outputs = [compile_commands],
        command = command,
        progress_message = "Building compile_commands.json {}".format(ctx.label),
    )
    return DefaultInfo(files = depset([compile_commands]))

kernel_compile_commands = rule(
    implementation = _kernel_compile_commands_impl,
    doc = """
Generate `compile_commands.json` from a `kernel_build`.
    """,
    attrs = {
        "kernel_build": attr.label(
            mandatory = True,
            doc = "The `kernel_build` rule to extract from.",
            providers = [KernelEnvInfo, KernelBuildInfo],
        ),
    },
)

def _kernel_kythe_impl(ctx):
    compile_commands = ctx.file.compile_commands
    all_kzip = ctx.actions.declare_file(ctx.attr.name + "/all.kzip")
    runextractor_error = ctx.actions.declare_file(ctx.attr.name + "/runextractor_error.log")
    intermediates_dir = utils.intermediates_dir(ctx)
    kzip_dir = intermediates_dir + "/kzip"
    extracted_kzip_dir = intermediates_dir + "/extracted"
    transitive_inputs = [src.files for src in ctx.attr.kernel_build[SrcsInfo].srcs]
    inputs = [compile_commands]
    inputs += ctx.attr.kernel_build[KernelEnvInfo].dependencies
    command = ctx.attr.kernel_build[KernelEnvInfo].setup
    command += """
             # Copy compile_commands.json to root
               cp {compile_commands} ${{ROOT_DIR}}
             # Prepare directories
               mkdir -p {kzip_dir} {extracted_kzip_dir} ${{OUT_DIR}}
             # Define env variables
               export KYTHE_ROOT_DIRECTORY=${{ROOT_DIR}}
               export KYTHE_OUTPUT_DIRECTORY={kzip_dir}
               export KYTHE_CORPUS="{corpus}"
             # Generate kzips
               runextractor compdb -extractor $(which cxx_extractor) 2> {runextractor_error} || true

             # Package it all into a single .kzip, ignoring duplicates.
               for zip in $(find {kzip_dir} -name '*.kzip'); do
                   unzip -qn "${{zip}}" -d {extracted_kzip_dir}
               done
               soong_zip -C {extracted_kzip_dir} -D {extracted_kzip_dir} -o {all_kzip}
             # Clean up directories
               rm -rf {kzip_dir}
               rm -rf {extracted_kzip_dir}
    """.format(
        compile_commands = compile_commands.path,
        kzip_dir = kzip_dir,
        extracted_kzip_dir = extracted_kzip_dir,
        corpus = ctx.attr.corpus,
        all_kzip = all_kzip.path,
        runextractor_error = runextractor_error.path,
    )
    ctx.actions.run_shell(
        mnemonic = "KernelKythe",
        inputs = depset(inputs, transitive = transitive_inputs),
        outputs = [all_kzip, runextractor_error],
        command = command,
        progress_message = "Building Kythe source code index (kzip) {}".format(ctx.label),
    )

    return DefaultInfo(files = depset([
        all_kzip,
        runextractor_error,
    ]))

kernel_kythe = rule(
    implementation = _kernel_kythe_impl,
    doc = """
Extract Kythe source code index (kzip file) from a `kernel_build`.
    """,
    attrs = {
        "kernel_build": attr.label(
            mandatory = True,
            doc = "The `kernel_build` target to extract from.",
            providers = [KernelEnvInfo, KernelBuildInfo],
            aspects = [srcs_aspect],
        ),
        "compile_commands": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "The `compile_commands.json`, or a `kernel_compile_commands` target.",
        ),
        "corpus": attr.string(
            default = "android.googlesource.com/kernel/superproject",
            doc = "The value of `KYTHE_CORPUS`. See [kythe.io/examples](https://kythe.io/examples).",
        ),
    },
)

def _kernel_extracted_symbols_impl(ctx):
    if ctx.attr.kernel_build_notrim[KernelBuildAbiInfo].trim_nonlisted_kmi:
        fail("{}: Requires `kernel_build` {} to have `trim_nonlisted_kmi = False`.".format(
            ctx.label,
            ctx.attr.kernel_build_notrim.label,
        ))

    if ctx.attr.kmi_symbol_list_add_only and not ctx.file.src:
        fail("{}: kmi_symbol_list_add_only requires kmi_symbol_list.".format(ctx.label))

    out = ctx.actions.declare_file("{}/extracted_symbols".format(ctx.attr.name))
    intermediates_dir = utils.intermediates_dir(ctx)

    gki_modules_list = ctx.attr.gki_modules_list_kernel_build[KernelBuildAbiInfo].module_outs_file
    vmlinux = find_file(name = "vmlinux", files = ctx.files.kernel_build_notrim, what = "{}: kernel_build_notrim".format(ctx.attr.name), required = True)
    in_tree_modules = find_files(suffix = ".ko", files = ctx.files.kernel_build_notrim, what = "{}: kernel_build_notrim".format(ctx.attr.name))
    srcs = [
        gki_modules_list,
        vmlinux,
    ]
    srcs += in_tree_modules
    for kernel_module in ctx.attr.kernel_modules:  # external modules
        srcs += kernel_module[KernelModuleInfo].files

    inputs = [ctx.file._extract_symbols]
    inputs += srcs
    inputs += ctx.attr.kernel_build_notrim[KernelEnvInfo].dependencies

    cp_src_cmd = ""
    flags = ["--symbol-list", out.path]
    flags += ["--gki-modules", gki_modules_list.path]
    if not ctx.attr.module_grouping:
        flags.append("--skip-module-grouping")
    if ctx.attr.kmi_symbol_list_add_only:
        flags.append("--additions-only")
        inputs.append(ctx.file.src)

        # Follow symlinks because we are in the execroot.
        # Do not preserve permissions because we are overwriting the file immediately.
        cp_src_cmd = "cp -L {src} {out}".format(
            src = ctx.file.src.path,
            out = out.path,
        )

    command = ctx.attr.kernel_build_notrim[KernelEnvInfo].setup
    command += """
        mkdir -p {intermediates_dir}
        cp -pl {srcs} {intermediates_dir}
        {cp_src_cmd}
        {extract_symbols} {flags} {intermediates_dir}
        rm -rf {intermediates_dir}
    """.format(
        srcs = " ".join([file.path for file in srcs]),
        intermediates_dir = intermediates_dir,
        extract_symbols = ctx.file._extract_symbols.path,
        flags = " ".join(flags),
        cp_src_cmd = cp_src_cmd,
    )
    debug.print_scripts(ctx, command)
    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [out],
        command = command,
        progress_message = "Extracting symbols {}".format(ctx.label),
        mnemonic = "KernelExtractedSymbols",
    )

    return DefaultInfo(files = depset([out]))

_kernel_extracted_symbols = rule(
    implementation = _kernel_extracted_symbols_impl,
    attrs = {
        # We can't use kernel_filegroup + hermetic_tools here because
        # - extract_symbols depends on the clang toolchain, which requires us to
        #   know the toolchain_version ahead of time.
        # - We also don't have the necessity to extract symbols from prebuilts.
        "kernel_build_notrim": attr.label(providers = [KernelEnvInfo, KernelBuildAbiInfo]),
        "kernel_modules": attr.label_list(providers = [KernelModuleInfo]),
        "module_grouping": attr.bool(default = True),
        "src": attr.label(doc = "Source `abi_gki_*` file. Used when `kmi_symbol_list_add_only`.", allow_single_file = True),
        "kmi_symbol_list_add_only": attr.bool(),
        "gki_modules_list_kernel_build": attr.label(doc = "The `kernel_build` which `module_outs` is treated as GKI modules list.", providers = [KernelBuildAbiInfo]),
        "_extract_symbols": attr.label(default = "//build/kernel:abi/extract_symbols", allow_single_file = True),
        "_debug_print_scripts": attr.label(default = "//build/kernel/kleaf:debug_print_scripts"),
    },
)

def _kernel_abi_dump_impl(ctx):
    full_abi_out_file = _kernel_abi_dump_full(ctx)
    abi_out_file = _kernel_abi_dump_filtered(ctx, full_abi_out_file)
    return [
        DefaultInfo(files = depset([full_abi_out_file, abi_out_file])),
        OutputGroupInfo(abi_out_file = depset([abi_out_file])),
    ]

def _kernel_abi_dump_epilog_cmd(path, append_version):
    ret = ""
    if append_version:
        ret += """
             # Append debug information to abi file
               echo "
<!--
     libabigail: $(abidw --version)
-->" >> {path}
""".format(path = path)
    return ret

def _kernel_abi_dump_full(ctx):
    abi_linux_tree = utils.intermediates_dir(ctx) + "/abi_linux_tree"
    full_abi_out_file = ctx.actions.declare_file("{}/abi-full.xml".format(ctx.attr.name))
    vmlinux = find_file(name = "vmlinux", files = ctx.files.kernel_build, what = "{}: kernel_build".format(ctx.attr.name), required = True)

    unstripped_dir_provider_targets = [ctx.attr.kernel_build] + ctx.attr.kernel_modules
    unstripped_dir_providers = [target[KernelUnstrippedModulesInfo] for target in unstripped_dir_provider_targets]
    for prov, target in zip(unstripped_dir_providers, unstripped_dir_provider_targets):
        if not prov.directory:
            fail("{}: Requires dep {} to set collect_unstripped_modules = True".format(ctx.label, target.label))
    unstripped_dirs = [prov.directory for prov in unstripped_dir_providers]

    inputs = [vmlinux, ctx.file._dump_abi]
    inputs += ctx.files._dump_abi_scripts
    inputs += unstripped_dirs

    inputs += ctx.attr._hermetic_tools[HermeticToolsInfo].deps

    # Directories could be empty, so use a find + cp
    command = ctx.attr._hermetic_tools[HermeticToolsInfo].setup + """
        mkdir -p {abi_linux_tree}
        find {unstripped_dirs} -name '*.ko' -exec cp -pl -t {abi_linux_tree} {{}} +
        cp -pl {vmlinux} {abi_linux_tree}
        {dump_abi} --linux-tree {abi_linux_tree} --out-file {full_abi_out_file}
        {epilog}
        rm -rf {abi_linux_tree}
    """.format(
        abi_linux_tree = abi_linux_tree,
        unstripped_dirs = " ".join([unstripped_dir.path for unstripped_dir in unstripped_dirs]),
        dump_abi = ctx.file._dump_abi.path,
        vmlinux = vmlinux.path,
        full_abi_out_file = full_abi_out_file.path,
        epilog = _kernel_abi_dump_epilog_cmd(full_abi_out_file.path, True),
    )
    debug.print_scripts(ctx, command)
    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [full_abi_out_file],
        command = command,
        mnemonic = "AbiDumpFull",
        progress_message = "Extracting ABI {}".format(ctx.label),
    )
    return full_abi_out_file

def _kernel_abi_dump_filtered(ctx, full_abi_out_file):
    abi_out_file = ctx.actions.declare_file("{}/abi.xml".format(ctx.attr.name))
    inputs = [full_abi_out_file]

    inputs += ctx.attr._hermetic_tools[HermeticToolsInfo].deps
    command = ctx.attr._hermetic_tools[HermeticToolsInfo].setup
    combined_abi_symbollist = ctx.attr.kernel_build[KernelBuildAbiInfo].combined_abi_symbollist
    if combined_abi_symbollist:
        inputs += [
            ctx.file._filter_abi,
            combined_abi_symbollist,
        ]

        command += """
            {filter_abi} --in-file {full_abi_out_file} --out-file {abi_out_file} --kmi-symbol-list {abi_symbollist}
            {epilog}
        """.format(
            abi_out_file = abi_out_file.path,
            full_abi_out_file = full_abi_out_file.path,
            filter_abi = ctx.file._filter_abi.path,
            abi_symbollist = combined_abi_symbollist.path,
            epilog = _kernel_abi_dump_epilog_cmd(abi_out_file.path, False),
        )
    else:
        command += """
            cp -p {full_abi_out_file} {abi_out_file}
        """.format(
            abi_out_file = abi_out_file.path,
            full_abi_out_file = full_abi_out_file.path,
        )
    debug.print_scripts(ctx, command)
    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [abi_out_file],
        command = command,
        mnemonic = "AbiDumpFiltered",
        progress_message = "Filtering ABI dump {}".format(ctx.label),
    )
    return abi_out_file

_kernel_abi_dump = rule(
    implementation = _kernel_abi_dump_impl,
    doc = "Extracts the ABI.",
    attrs = {
        "kernel_build": attr.label(providers = [KernelEnvInfo, KernelBuildAbiInfo, KernelUnstrippedModulesInfo]),
        "kernel_modules": attr.label_list(providers = [KernelUnstrippedModulesInfo]),
        "_dump_abi_scripts": attr.label(default = "//build/kernel:dump-abi-scripts"),
        "_dump_abi": attr.label(default = "//build/kernel:abi/dump_abi", allow_single_file = True),
        "_filter_abi": attr.label(default = "//build/kernel:abi/filter_abi", allow_single_file = True),
        "_hermetic_tools": attr.label(default = "//build/kernel:hermetic-tools", providers = [HermeticToolsInfo]),
        "_debug_print_scripts": attr.label(default = "//build/kernel/kleaf:debug_print_scripts"),
    },
)

def _kernel_abi_prop_impl(ctx):
    content = []
    if ctx.file.kmi_definition:
        content.append("KMI_DEFINITION={}".format(ctx.file.kmi_definition.basename))
        content.append("KMI_MONITORED=1")

        if ctx.attr.kmi_enforced:
            content.append("KMI_ENFORCED=1")

    combined_abi_symbollist = ctx.attr.kernel_build[KernelBuildAbiInfo].combined_abi_symbollist
    if combined_abi_symbollist:
        content.append("KMI_SYMBOL_LIST={}".format(combined_abi_symbollist.basename))

    # This just appends `KERNEL_BINARY=vmlinux`, but find_file additionally ensures that
    # we are building vmlinux.
    vmlinux = find_file(name = "vmlinux", files = ctx.files.kernel_build, what = "{}: kernel_build".format(ctx.attr.name), required = True)
    content.append("KERNEL_BINARY={}".format(vmlinux.basename))

    if ctx.file.modules_archive:
        content.append("MODULES_ARCHIVE={}".format(ctx.file.modules_archive.basename))

    out = ctx.actions.declare_file("{}/abi.prop".format(ctx.attr.name))
    ctx.actions.write(
        output = out,
        content = "\n".join(content) + "\n",
    )
    return DefaultInfo(files = depset([out]))

_kernel_abi_prop = rule(
    implementation = _kernel_abi_prop_impl,
    doc = "Create `abi.prop`",
    attrs = {
        "kernel_build": attr.label(providers = [KernelBuildAbiInfo]),
        "modules_archive": attr.label(allow_single_file = True),
        "kmi_definition": attr.label(allow_single_file = True),
        "kmi_enforced": attr.bool(),
    },
)

def kernel_build_abi(
        name,
        define_abi_targets = None,
        # for kernel_abi
        kernel_modules = None,
        module_grouping = None,
        abi_definition = None,
        kmi_enforced = None,
        unstripped_modules_archive = None,
        kmi_symbol_list_add_only = None,
        # for kernel_build
        **kwargs):
    """Declare multiple targets to support ABI monitoring.

    This macro is meant to be used in place of the [`kernel_build`](#kernel_build)
    marco. All arguments in `kwargs` are passed to `kernel_build` directly.

    For example, you may have the following declaration. (For actual definition
    of `kernel_aarch64`, see
    [`define_common_kernels()`](#define_common_kernels).

    ```
    kernel_build_abi(name = "kernel_aarch64", **kwargs)
    _dist_targets = ["kernel_aarch64", ...]
    copy_to_dist_dir(name = "kernel_aarch64_dist", data = _dist_targets)
    kernel_build_abi_dist(
        name = "kernel_aarch64_abi_dist",
        kernel_build_abi = "kernel_aarch64",
        data = _dist_targets,
    )
    ```

    The `kernel_build_abi` invocation is equivalent to the following:

    ```
    kernel_build(name = "kernel_aarch64", **kwargs)
    # if define_abi_targets, also define some other targets
    ```

    See [`kernel_build`](#kernel_build) for the targets defined.

    In addition, the following targets are defined:
    - `kernel_aarch64_abi_dump`
      - Building this target extracts the ABI.
      - Include this target in a [`kernel_build_abi_dist`](#kernel_build_abi_dist)
        target to copy ABI dump to `--dist-dir`.
    - `kernel_aarch64_abi`
      - A filegroup that contains `kernel_aarch64_abi_dump`. It also contains other targets
        if `define_abi_targets = True`; see below.

    In addition, the following targets are defined if `define_abi_targets = True`:
    - `kernel_aarch64_abi_update_symbol_list`
      - Running this target updates `kmi_symbol_list`.
    - `kernel_aarch64_abi_update`
      - Running this target updates `abi_definition`.
    - `kernel_aarch64_abi_dump`
      - Building this target extracts the ABI.
      - Include this target in a [`kernel_build_abi_dist`](#kernel_build_abi_dist)
        target to copy ABI dump to `--dist-dir`.

    See build/kernel/kleaf/abi.md for a conversion chart from `build_abi.sh`
    commands to Bazel commands.

    Args:
      name: Name of the main `kernel_build`.
      define_abi_targets: Whether the `<name>_abi` target contains other
        files to support ABI monitoring. If `None`, defaults to `True`.

        If `False`, this macro is equivalent to just calling
        ```
        kernel_build(name = name, **kwargs)
        filegroup(name = name + "_abi", data = [name, abi_dump_target])
        ```

        If `True`, implies `collect_unstripped_modules = True`. See
        [`kernel_build.collect_unstripped_modules`](#kernel_build-collect_unstripped_modules).
      kernel_modules: A list of external [`kernel_module()`](#kernel_module)s
        to extract symbols from.
      module_grouping: If unspecified or `None`, it is `True` by default.
        If `True`, then the symbol list will group symbols based
        on the kernel modules that reference the symbol. Otherwise the symbol
        list will simply be a sorted list of symbols used by all the kernel
        modules.
      abi_definition: Location of the ABI definition.
      kmi_enforced: This is an indicative option to signal that KMI is enforced.
        If set to `True`, KMI checking tools respects it and
        reacts to it by failing if KMI differences are detected.
      unstripped_modules_archive: A [`kernel_unstripped_modules_archive`](#kernel_unstripped_modules_archive)
        which name is specified in `abi.prop`.
      kmi_symbol_list_add_only: If unspecified or `None`, it is `False` by
        default. If `True`,
        then any symbols in the symbol list that would have been
        removed are preserved (at the end of the file). Symbol list update will
        fail if there is no pre-existing symbol list file to read from. This
        property is intended to prevent unintentional shrinkage of a stable ABI.

        This should be set to `True` if `KMI_SYMBOL_LIST_ADD_ONLY=1`.
      kwargs: See [`kernel_build.kwargs`](#kernel_build-kwargs)
    """

    if define_abi_targets == None:
        define_abi_targets = True

    kwargs = dict(kwargs)
    if kwargs.get("collect_unstripped_modules") == None:
        kwargs["collect_unstripped_modules"] = True

    _kernel_build_abi_define_other_targets(
        name = name,
        define_abi_targets = define_abi_targets,
        kernel_modules = kernel_modules,
        module_grouping = module_grouping,
        kmi_symbol_list_add_only = kmi_symbol_list_add_only,
        abi_definition = abi_definition,
        kmi_enforced = kmi_enforced,
        unstripped_modules_archive = unstripped_modules_archive,
        kernel_build_kwargs = kwargs,
    )

    kernel_build(name = name, **kwargs)

def _kernel_build_abi_define_other_targets(
        name,
        define_abi_targets,
        kernel_modules,
        module_grouping,
        kmi_symbol_list_add_only,
        abi_definition,
        kmi_enforced,
        unstripped_modules_archive,
        kernel_build_kwargs):
    """Helper to `kernel_build_abi`.

    Defines targets other than the main `kernel_build()`.

    Defines:
    * `{name}_with_vmlinux`
    * `{name}_notrim` (if `define_abi_targets`)
    * `{name}_abi_diff_executable`
    * `{name}_abi`
    """
    new_outs, outs_changed = kernel_utils.kernel_build_outs_add_vmlinux(name, kernel_build_kwargs.get("outs"))

    # with_vmlinux: outs += [vmlinux]
    if outs_changed or kernel_build_kwargs.get("base_kernel"):
        with_vmlinux_kwargs = dict(kernel_build_kwargs)
        with_vmlinux_kwargs["outs"] = kernel_utils.transform_kernel_build_outs(name + "_with_vmlinux", "outs", new_outs)
        with_vmlinux_kwargs["base_kernel_for_module_outs"] = with_vmlinux_kwargs.pop("base_kernel", default = None)
        kernel_build(name = name + "_with_vmlinux", **with_vmlinux_kwargs)
    else:
        native.alias(name = name + "_with_vmlinux", actual = name)

    _kernel_abi_dump(
        name = name + "_abi_dump",
        kernel_build = name + "_with_vmlinux",
        kernel_modules = [module + "_with_vmlinux" for module in kernel_modules] if kernel_modules else kernel_modules,
    )

    if not define_abi_targets:
        _kernel_build_abi_not_define_abi_targets(
            name = name,
            abi_dump_target = name + "_abi_dump",
        )
    else:
        _kernel_build_abi_define_abi_targets(
            name = name,
            kernel_modules = kernel_modules,
            module_grouping = module_grouping,
            kmi_symbol_list_add_only = kmi_symbol_list_add_only,
            abi_definition = abi_definition,
            kmi_enforced = kmi_enforced,
            unstripped_modules_archive = unstripped_modules_archive,
            outs_changed = outs_changed,
            new_outs = new_outs,
            abi_dump_target = name + "_abi_dump",
            kernel_build_with_vmlinux_target = name + "_with_vmlinux",
            kernel_build_kwargs = kernel_build_kwargs,
        )

def _kernel_build_abi_not_define_abi_targets(
        name,
        abi_dump_target):
    """Helper to `_kernel_build_abi_define_other_targets` when `define_abi_targets = False.`

    Defines `{name}_abi` filegroup that only contains the ABI dump, provided
    in `abi_dump_target`.

    Defines:
    * `{name}_abi_diff_executable`
    * `{name}_abi`
    """
    native.filegroup(
        name = name + "_abi",
        srcs = [abi_dump_target],
    )

    # For kernel_build_abi_dist to use when define_abi_targets is not set.
    exec(
        name = name + "_abi_diff_executable",
        script = "",
    )

def _kernel_build_abi_define_abi_targets(
        name,
        kernel_modules,
        module_grouping,
        kmi_symbol_list_add_only,
        abi_definition,
        kmi_enforced,
        unstripped_modules_archive,
        outs_changed,
        new_outs,
        abi_dump_target,
        kernel_build_with_vmlinux_target,
        kernel_build_kwargs):
    """Helper to `_kernel_build_abi_define_other_targets` when `define_abi_targets = True.`

    Define targets to extract symbol list, extract ABI, update them, etc.

    Defines:
    * `{name}_notrim`
    * `{name}_abi_diff_executable`
    * `{name}_abi`
    """

    default_outputs = [abi_dump_target]

    # notrim: outs += [vmlinux], trim_nonlisted_kmi = False
    if kernel_build_kwargs.get("trim_nonlisted_kmi") or outs_changed or kernel_build_kwargs.get("base_kernel"):
        notrim_kwargs = dict(kernel_build_kwargs)
        notrim_kwargs["outs"] = kernel_utils.transform_kernel_build_outs(name + "_notrim", "outs", new_outs)
        notrim_kwargs["trim_nonlisted_kmi"] = False
        notrim_kwargs["kmi_symbol_list_strict_mode"] = False
        notrim_kwargs["base_kernel_for_module_outs"] = notrim_kwargs.pop("base_kernel", default = None)
        kernel_build(name = name + "_notrim", **notrim_kwargs)
    else:
        native.alias(name = name + "_notrim", actual = name)

    # extract_symbols ...
    _kernel_extracted_symbols(
        name = name + "_abi_extracted_symbols",
        kernel_build_notrim = name + "_notrim",
        kernel_modules = [module + "_notrim" for module in kernel_modules] if kernel_modules else kernel_modules,
        module_grouping = module_grouping,
        src = kernel_build_kwargs.get("kmi_symbol_list"),
        kmi_symbol_list_add_only = kmi_symbol_list_add_only,
        # If base_kernel is set, this is a device build, so use the GKI
        # modules list from base_kernel (GKI). If base_kernel is not set, this
        # likely a GKI build, so use modules_outs from itself.
        gki_modules_list_kernel_build = kernel_build_kwargs.get("base_kernel", name),
    )
    update_source_file(
        name = name + "_abi_update_symbol_list",
        src = name + "_abi_extracted_symbols",
        dst = kernel_build_kwargs.get("kmi_symbol_list"),
    )

    default_outputs += _kernel_build_abi_define_abi_definition_targets(
        name = name,
        abi_definition = abi_definition,
        kmi_enforced = kmi_enforced,
        kmi_symbol_list = kernel_build_kwargs.get("kmi_symbol_list"),
    )

    _kernel_abi_prop(
        name = name + "_abi_prop",
        kmi_definition = name + "_abi_out_file" if abi_definition else None,
        kmi_enforced = kmi_enforced,
        kernel_build = kernel_build_with_vmlinux_target,
        modules_archive = unstripped_modules_archive,
    )
    default_outputs.append(name + "_abi_prop")

    native.filegroup(
        name = name + "_abi",
        srcs = default_outputs,
    )

def _kernel_build_abi_define_abi_definition_targets(
        name,
        abi_definition,
        kmi_enforced,
        kmi_symbol_list):
    """Helper to `_kernel_build_abi_define_abi_targets`.

    Defines targets to extract ABI, update ABI, compare ABI, etc. etc.

    Defines `{name}_abi_diff_executable`.
    """
    if not abi_definition:
        # For kernel_build_abi_dist to use when abi_definition is empty.
        exec(
            name = name + "_abi_diff_executable",
            script = "",
        )
        return []

    default_outputs = []

    native.filegroup(
        name = name + "_abi_out_file",
        srcs = [name + "_abi_dump"],
        output_group = "abi_out_file",
    )

    _kernel_abi_diff(
        name = name + "_abi_diff",
        baseline = abi_definition,
        new = name + "_abi_out_file",
        kmi_enforced = kmi_enforced,
    )
    default_outputs.append(name + "_abi_diff")

    # The default outputs of _abi_diff does not contain the executable,
    # but the reports. Use this filegroup to select the executable
    # so rootpath in _abi_update works.
    native.filegroup(
        name = name + "_abi_diff_executable",
        srcs = [name + "_abi_diff"],
        output_group = "executable",
    )

    update_source_file(
        name = name + "_abi_update_definition",
        src = name + "_abi_out_file",
        dst = abi_definition,
    )

    exec(
        name = name + "_abi_nodiff_update",
        data = [
            name + "_abi_extracted_symbols",
            name + "_abi_update_definition",
            kmi_symbol_list,
        ],
        script = """
              # Ensure that symbol list is updated
                if ! diff -q $(rootpath {src_symbol_list}) $(rootpath {dst_symbol_list}); then
                  echo "ERROR: symbol list must be updated before updating ABI definition. To update, execute 'tools/bazel run //{package}:{update_symbol_list_label}'." >&2
                  exit 1
                fi
              # Update abi_definition
                $(rootpath {update_definition})
            """.format(
            src_symbol_list = name + "_abi_extracted_symbols",
            dst_symbol_list = kmi_symbol_list,
            package = native.package_name(),
            update_symbol_list_label = name + "_abi_update_symbol_list",
            update_definition = name + "_abi_update_definition",
        ),
    )

    exec(
        name = name + "_abi_update",
        data = [
            name + "_abi_diff_executable",
            name + "_abi_nodiff_update",
        ],
        script = """
              # Update abi_definition
                $(rootpath {nodiff_update})
              # Check return code of diff_abi and kmi_enforced
                $(rootpath {diff})
            """.format(
            diff = name + "_abi_diff_executable",
            nodiff_update = name + "_abi_nodiff_update",
        ),
    )

    return default_outputs

def kernel_build_abi_dist(
        name,
        kernel_build_abi,
        **kwargs):
    """A wrapper over `copy_to_dist_dir` for [`kernel_build_abi`](#kernel_build_abi).

    After copying all files to dist dir, return the exit code from `diff_abi`.

    Args:
      name: name of the dist target
      kernel_build_abi: name of the [`kernel_build_abi`](#kernel_build_abi)
        invocation.
    """

    # TODO(b/231647455): Clean up hard-coded name "_abi" and "_abi_diff_executable".

    if kwargs.get("data") == None:
        kwargs["data"] = []

    # Use explicit + to prevent modifying the original list.
    kwargs["data"] = kwargs["data"] + [kernel_build_abi + "_abi"]

    copy_to_dist_dir(
        name = name + "_copy_to_dist_dir",
        **kwargs
    )

    exec(
        name = name,
        data = [
            name + "_copy_to_dist_dir",
            kernel_build_abi + "_abi_diff_executable",
        ],
        script = """
          # Copy to dist dir
            $(rootpath {copy_to_dist_dir}) $@
          # Check return code of diff_abi and kmi_enforced
            $(rootpath {diff})
        """.format(
            copy_to_dist_dir = name + "_copy_to_dist_dir",
            diff = kernel_build_abi + "_abi_diff_executable",
        ),
    )

def _kernel_abi_diff_impl(ctx):
    inputs = [
        ctx.file._diff_abi,
        ctx.file.baseline,
        ctx.file.new,
    ]
    inputs += ctx.attr._hermetic_tools[HermeticToolsInfo].deps
    inputs += ctx.files._diff_abi_scripts

    output_dir = ctx.actions.declare_directory("{}/abi_diff".format(ctx.attr.name))
    error_msg_file = ctx.actions.declare_file("{}/error_msg_file".format(ctx.attr.name))
    exit_code_file = ctx.actions.declare_file("{}/exit_code_file".format(ctx.attr.name))
    default_outputs = [output_dir]

    command_outputs = default_outputs + [
        error_msg_file,
        exit_code_file,
    ]

    command = ctx.attr._hermetic_tools[HermeticToolsInfo].setup + """
        set +e
        {diff_abi} --baseline {baseline}                \\
                   --new      {new}                     \\
                   --report   {output_dir}/abi.report   \\
                   --abi-tool delegated > {error_msg_file} 2>&1
        rc=$?
        set -e
        echo $rc > {exit_code_file}
        if [[ $rc == 0 ]]; then
            echo "INFO: $(cat {error_msg_file})"
        else
            echo "ERROR: $(cat {error_msg_file})" >&2
            echo "INFO: exit code is not checked. 'tools/bazel run {label}' to check the exit code." >&2
        fi
    """.format(
        diff_abi = ctx.file._diff_abi.path,
        baseline = ctx.file.baseline.path,
        new = ctx.file.new.path,
        output_dir = output_dir.path,
        exit_code_file = exit_code_file.path,
        error_msg_file = error_msg_file.path,
        label = ctx.label,
    )

    debug.print_scripts(ctx, command)
    ctx.actions.run_shell(
        inputs = inputs,
        outputs = command_outputs,
        command = command,
        mnemonic = "KernelDiffAbi",
        progress_message = "Comparing ABI {}".format(ctx.label),
    )

    script = ctx.actions.declare_file("{}/print_results.sh".format(ctx.attr.name))
    script_content = """#!/bin/bash -e
        rc=$(cat {exit_code_file})
        if [[ $rc == 0 ]]; then
            echo "INFO: $(cat {error_msg_file})"
        else
            echo "ERROR: $(cat {error_msg_file})" >&2
        fi
""".format(
        exit_code_file = exit_code_file.short_path,
        error_msg_file = error_msg_file.short_path,
    )
    if ctx.attr.kmi_enforced:
        script_content += """
            exit $rc
        """
    ctx.actions.write(script, script_content, is_executable = True)

    return [
        DefaultInfo(
            files = depset(default_outputs),
            executable = script,
            runfiles = ctx.runfiles(files = command_outputs),
        ),
        OutputGroupInfo(executable = depset([script])),
    ]

_kernel_abi_diff = rule(
    implementation = _kernel_abi_diff_impl,
    doc = "Run `diff_abi`",
    attrs = {
        "baseline": attr.label(allow_single_file = True),
        "new": attr.label(allow_single_file = True),
        "kmi_enforced": attr.bool(),
        "_hermetic_tools": attr.label(default = "//build/kernel:hermetic-tools", providers = [HermeticToolsInfo]),
        "_diff_abi_scripts": attr.label(default = "//build/kernel:diff-abi-scripts"),
        "_diff_abi": attr.label(default = "//build/kernel:abi/diff_abi", allow_single_file = True),
        "_debug_print_scripts": attr.label(default = "//build/kernel/kleaf:debug_print_scripts"),
    },
    executable = True,
)

def _kernel_unstripped_modules_archive_impl(ctx):
    kernel_build = ctx.attr.kernel_build
    base_kernel = kernel_build[KernelUnstrippedModulesInfo].base_kernel if kernel_build else None

    # Early elements = higher priority. In-tree modules from base_kernel has highest priority,
    # then in-tree modules of the device kernel_build, then external modules (in an undetermined
    # order).
    # TODO(b/228557644): kernel module names should not collide. Detect collsions.
    srcs = []
    for kernel_build_object in (base_kernel, kernel_build):
        if not kernel_build_object:
            continue
        directory = kernel_build_object[KernelUnstrippedModulesInfo].directory
        if not directory:
            fail("{} does not have collect_unstripped_modules = True.".format(kernel_build_object.label))
        srcs.append(directory)
    for kernel_module in ctx.attr.kernel_modules:
        srcs.append(kernel_module[KernelUnstrippedModulesInfo].directory)

    inputs = ctx.attr._hermetic_tools[HermeticToolsInfo].deps + srcs

    out_file = ctx.actions.declare_file("{}/unstripped_modules.tar.gz".format(ctx.attr.name))
    unstripped_dir = ctx.genfiles_dir.path + "/unstripped"

    command = ""
    command += ctx.attr._hermetic_tools[HermeticToolsInfo].setup
    command += """
        mkdir -p {unstripped_dir}
    """.format(unstripped_dir = unstripped_dir)

    # Copy the source ko files in low to high priority order.
    for src in reversed(srcs):
        # src could be empty, so use find + cp
        command += """
            find {src} -name '*.ko' -exec cp -l -t {unstripped_dir} {{}} +
        """.format(
            src = src.path,
            unstripped_dir = unstripped_dir,
        )

    command += """
        tar -czhf {out_file} -C $(dirname {unstripped_dir}) $(basename {unstripped_dir})
    """.format(
        out_file = out_file.path,
        unstripped_dir = unstripped_dir,
    )

    debug.print_scripts(ctx, command)
    ctx.actions.run_shell(
        inputs = inputs,
        outputs = [out_file],
        progress_message = "Compressing unstripped modules {}".format(ctx.label),
        command = command,
        mnemonic = "KernelUnstrippedModulesArchive",
    )
    return DefaultInfo(files = depset([out_file]))

kernel_unstripped_modules_archive = rule(
    implementation = _kernel_unstripped_modules_archive_impl,
    doc = """Compress the unstripped modules into a tarball.

This is the equivalent of `COMPRESS_UNSTRIPPED_MODULES=1` in `build.sh`.

Add this target to a `copy_to_dist_dir` rule to copy it to the distribution
directory, or `DIST_DIR`.
""",
    attrs = {
        "kernel_build": attr.label(
            doc = """A [`kernel_build`](#kernel_build) to retrieve unstripped in-tree modules from.

It requires `collect_unstripped_modules = True`. If the `kernel_build` has a `base_kernel`, the rule
also retrieves unstripped in-tree modules from the `base_kernel`, and requires the
`base_kernel` has `collect_unstripped_modules = True`.
""",
            providers = [KernelUnstrippedModulesInfo],
        ),
        "kernel_modules": attr.label_list(
            doc = """A list of external [`kernel_module`](#kernel_module)s to retrieve unstripped external modules from.

It requires that the base `kernel_build` has `collect_unstripped_modules = True`.
""",
            providers = [KernelUnstrippedModulesInfo],
        ),
        "_hermetic_tools": attr.label(default = "//build/kernel:hermetic-tools", providers = [HermeticToolsInfo]),
        "_debug_print_scripts": attr.label(default = "//build/kernel/kleaf:debug_print_scripts"),
    },
)
