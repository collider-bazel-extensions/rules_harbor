"""Maintainer-only chart fetch — fires only when rules_harbor is the root."""

load("//tools:repositories.bzl", "harbor_chart_repository")

_version_tag = tag_class(attrs = {
    "version": attr.string(mandatory = True),
})

def _impl(mctx):
    for mod in mctx.modules:
        if not mod.is_root:
            continue
        for tag in mod.tags.version:
            harbor_chart_repository(
                name = "harbor_chart_" + tag.version.replace(".", "_"),
                version = tag.version,
            )

harbor_chart = module_extension(
    implementation = _impl,
    tag_classes = {"version": _version_tag},
)
