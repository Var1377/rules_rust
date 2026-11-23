"""`cargo check` for Bazel: rust_check_aspect."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_cc//cc:find_cc_toolchain.bzl", "use_cc_toolchain")
load("//rust/private:common.bzl", "rust_common")
load("//rust/private:providers.bzl", "LintsInfo")
load("//rust/private:rustc.bzl", "collect_deps", "collect_inputs", "construct_arguments")
load("//rust/private:utils.bzl", "determine_output_hash", "find_cc_toolchain", "find_toolchain")

def _rust_check_aspect_impl(target, ctx):
    if rust_common.crate_info in target:
        crate_info = target[rust_common.crate_info]
    elif rust_common.test_crate_info in target:
        crate_info = target[rust_common.test_crate_info].crate
    else:
        return []
    toolchain = find_toolchain(ctx)
    cc_toolchain, feature_configuration = find_cc_toolchain(ctx)
    dep_info, build_info, _ = collect_deps(
        deps = crate_info.deps.to_list(),
        proc_macro_deps = crate_info.proc_macro_deps.to_list(),
        aliases = crate_info.aliases,
        extra_named_deps = crate_info.extra_named_deps,
    )
    # Under clippy_driver the check is the compile's own driver: clippy-driver, with the crate's clippy lints at their
    # declared levels, so a check lints what the compile lints and no clippy aspect type-checks the crate again.
    use_clippy = ctx.attr._clippy_driver[BuildSettingInfo].value
    if use_clippy and not toolchain.clippy_driver:
        fail("--@rules_rust//rust/settings:clippy_driver requires a toolchain with clippy-driver")
    tool = toolchain.clippy_driver if use_clippy else toolchain.rustc
    lint_flags, lint_files = [], []
    if getattr(ctx.rule.attr, "lint_config", None):
        lints = ctx.rule.attr.lint_config[LintsInfo]
        lint_flags = lints.rustc_lint_flags + (lints.clippy_lint_flags if use_clippy else [])
        lint_files = lints.rustc_lint_files + (lints.clippy_lint_files if use_clippy else [])
    compile_inputs, out_dir, build_env_files, build_flags_files, linkstamp_outs, ambiguous_libs = collect_inputs(
        ctx,
        ctx.rule.file,
        ctx.rule.files,
        depset([]),
        toolchain,
        cc_toolchain,
        feature_configuration,
        crate_info,
        dep_info,
        build_info,
        lint_files,
        depend_on_metadata = True,
    )
    args, env = construct_arguments(
        ctx = ctx,
        attr = ctx.rule.attr,
        file = ctx.file,
        toolchain = toolchain,
        tool_file = tool,
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
        crate_info = crate_info,
        dep_info = dep_info,
        linkstamp_outs = linkstamp_outs,
        ambiguous_libs = ambiguous_libs,
        output_hash = determine_output_hash(crate_info.root, ctx.label),
        rust_flags = [],
        out_dir = out_dir,
        build_env_files = build_env_files,
        build_flags_files = build_flags_files,
        emit = ["dep-info", "metadata"],
        use_json_output = True,
        depend_on_metadata = True,
        skip_expanding_rustc_env = True,
    )
    if crate_info.is_test:
        args.rustc_flags.add("--test")
    args.rustc_flags.add_all(lint_flags)
    marker = ctx.actions.declare_file(ctx.label.name + ".rust_check.ok")
    args.process_wrapper_flags.add("--touch-file", marker)

    # rustc's JSON diagnostics, each warning and error of the check, for a reader that judges them by line (a lint on
    # a line a change adds): one cached output with the verdict, so reading them runs nothing.
    diagnostics = ctx.actions.declare_file(ctx.label.name + ".rust_check.diagnostics")
    args.process_wrapper_flags.add("--output-file", diagnostics)
    if use_clippy:
        clippy_config = getattr(ctx.rule.file, "clippy_config", None) or ctx.file._clippy_config
        env["CLIPPY_CONF_DIR"] = clippy_config.dirname or "."
        compile_inputs = depset([clippy_config], transitive = [compile_inputs])
    ctx.actions.run(
        executable = ctx.executable._process_wrapper,
        inputs = compile_inputs,
        outputs = [marker, diagnostics],
        env = env,
        tools = [tool],
        arguments = args.all,
        mnemonic = "RustCheck",
        progress_message = "Checking %{label}",
        toolchain = "@rules_rust//rust:toolchain_type",
    )
    return [OutputGroupInfo(rust_check = depset([marker, diagnostics]))]

rust_check_aspect = aspect(
    fragments = ["cpp"],
    attrs = {
        "_clippy_config": attr.label(
            allow_single_file = True,
            default = Label("//rust/settings:clippy.toml"),
        ),
        "_clippy_driver": attr.label(default = Label("//rust/settings:clippy_driver")),
        "_error_format": attr.label(default = "//rust/settings:error_format"),
        "_extra_exec_rustc_env": attr.label(default = Label("//rust/settings:extra_exec_rustc_env")),
        "_extra_exec_rustc_flag": attr.label(default = Label("//rust/settings:extra_exec_rustc_flag")),
        "_extra_exec_rustc_flags": attr.label(default = Label("//rust/settings:extra_exec_rustc_flags")),
        "_extra_rustc_env": attr.label(default = Label("//rust/settings:extra_rustc_env")),
        "_extra_rustc_flags": attr.label(default = Label("//rust/settings:extra_rustc_flags")),
        "_extra_rustc_flag": attr.label(default = Label("//rust/settings:extra_rustc_flag")),
        "_per_crate_rustc_flag": attr.label(default = Label("//rust/settings:per_crate_rustc_flag")),
        "_process_wrapper": attr.label(
            default = Label("//util/process_wrapper"),
            executable = True,
            cfg = "exec",
        ),
    },
    required_providers = [
        [rust_common.crate_info],
        [rust_common.test_crate_info],
    ],
    toolchains = [
        str(Label("//rust:toolchain_type")),
    ] + use_cc_toolchain(mandatory = False),
    implementation = _rust_check_aspect_impl,
    doc = """\
Type-checks each requested crate to its metadata, as `cargo check` does: no code generation and no link for it.

Its dependencies are their metadata, whatever the crate type (a test or a binary too): a check never links, so it
waits on no dependency's code generation, and an unchanged dependency is a cache hit. Build the `rust_check` output group:
`bazel build --aspects=@rules_rust//rust:defs.bzl%rust_check_aspect --output_groups=rust_check //pkg:all`.

Under `--@rules_rust//rust/settings:clippy_driver` the check runs clippy-driver with each crate's clippy lints at their
declared levels: a denied lint fails it. Each check writes rustc's JSON diagnostics to `<name>.rust_check.diagnostics`
in the same output group.
""",
)
