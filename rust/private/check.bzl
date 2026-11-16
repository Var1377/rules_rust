"""`cargo check` for Bazel: rust_check_aspect."""

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
    lint_flags, lint_files = [], []
    if getattr(ctx.rule.attr, "lint_config", None):
        lint_flags = ctx.rule.attr.lint_config[LintsInfo].rustc_lint_flags
        lint_files = ctx.rule.attr.lint_config[LintsInfo].rustc_lint_files
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
    )
    args, env = construct_arguments(
        ctx = ctx,
        attr = ctx.rule.attr,
        file = ctx.file,
        toolchain = toolchain,
        tool_file = toolchain.rustc,
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
        skip_expanding_rustc_env = True,
    )
    if crate_info.is_test:
        args.rustc_flags.add("--test")
    args.rustc_flags.add_all(lint_flags)
    marker = ctx.actions.declare_file(ctx.label.name + ".rust_check.ok")
    args.process_wrapper_flags.add("--touch-file", marker)
    ctx.actions.run(
        executable = ctx.executable._process_wrapper,
        inputs = compile_inputs,
        outputs = [marker],
        env = env,
        tools = [toolchain.rustc],
        arguments = args.all,
        mnemonic = "RustCheck",
        progress_message = "Checking %{label}",
        toolchain = "@rules_rust//rust:toolchain_type",
    )
    return [OutputGroupInfo(rust_check = depset([marker]))]

rust_check_aspect = aspect(
    fragments = ["cpp"],
    attrs = {
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

Its dependencies are their ordinary outputs, the ones every other build shares, so an unchanged dependency is a
cache hit. Build the `rust_check` output group:
`bazel build --aspects=@rules_rust//rust:defs.bzl%rust_check_aspect --output_groups=rust_check //pkg:all`.
""",
)
