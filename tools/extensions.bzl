"""Maintainer-only chart fetch — fires only when rules_mimir is the root."""

load("//tools:repositories.bzl", "mimir_chart_repository")

_version_tag = tag_class(attrs = {
    "version": attr.string(mandatory = True),
})

def _impl(mctx):
    for mod in mctx.modules:
        if not mod.is_root:
            continue
        for tag in mod.tags.version:
            mimir_chart_repository(
                name = "mimir_chart_" + tag.version.replace(".", "_"),
                version = tag.version,
            )

mimir_chart = module_extension(
    implementation = _impl,
    tag_classes = {"version": _version_tag},
)
