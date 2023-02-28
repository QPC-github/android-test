"""Skylark rule to create a maven repository from a single artifact."""

_pom_tmpl = "\n".join([
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<project xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd"',
    '    xmlns="http://maven.apache.org/POM/4.0.0"',
    '    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">',
    "  <modelVersion>4.0.0</modelVersion>",
    "  <groupId>{group_id}</groupId>",
    "  <artifactId>{artifact_id}</artifactId>",
    "  <version>{version}</version>",
    "  <packaging>{packaging}</packaging>",
    "  <name>AndroidX Test Library</name>",
    "  <description>The AndroidX Test Library provides an extensive framework for testing Android apps</description>",
    "  <url>https://developer.android.com/testing</url>",
    "  <inceptionYear>2015</inceptionYear>",
    "  <licenses>",
    "{licenses}",
    "  </licenses>",
    "  <developers>",
    "    <developer>",
    "      <name>The Android Open Source Project</name>",
    "    </developer>",
    "  </developers>",
    "  <dependencies>",
    "{dependencies}",
    "  </dependencies>",
    "</project>",
    "",
])

_dependency_tmpl = "\n".join([
    "    <dependency>",
    "      <groupId>{group_id}</groupId>",
    "      <artifactId>{artifact_id}</artifactId>",
    "      <version>{version}</version>",
    "      <scope>compile</scope>",
    "    </dependency>",
])

_metadata_tmpl = "\n".join([
    '<?xml version="1.0" encoding="UTF-8"?>',
    "<metadata>",
    "  <groupId>{group_id}</groupId>",
    "  <artifactId>{artifact_id}</artifactId>",
    "  <version>{version}</version>",
    "  <versioning>",
    "    <release>{version}</release>",
    "    <versions>",
    "      <version>{version}</version>",
    "    </versions>",
    "  <lastUpdated>{last_updated}</lastUpdated>",
    "  </versioning>",
    "</metadata>",
    "",
])

_license_impl = "\n".join([
    "    <license>",
    "      <name>{name}</name>",
    "      <url>{url}</url>",
    "      <distribution>repo</distribution>",
    "    </license>",
])

def _packaging_type(f):
    """Returns the packaging type used by the file f."""
    if f.basename.endswith(".aar"):
        return "aar"
    elif f.basename.endswith(".apk"):
        return "apk"
    elif f.basename.endswith(".jar"):
        return "jar"
    fail("Artifact has unknown packaging type: %s" % f.short_path)

def _create_pom_string(ctx):
    """Returns the contents of the pom file as a string."""
    dependencies = []
    for dep in ctx.attr.artifact_deps:
        if dep.count(":") != 2:
            fail("artifact_deps values must be of form: groupId:artifactId:version")

        group_id, artifact_id, version = dep.split(":")
        dependencies.append(_dependency_tmpl.format(
            group_id = group_id,
            artifact_id = artifact_id,
            version = version,
        ))

    licenses = []
    if ctx.attr.license_name and ctx.attr.license_url:
        licenses.append(_license_impl.format(
            name = ctx.attr.license_name,
            url = ctx.attr.license_url,
        ))
    else:
        licenses.append(_license_impl.format(
            name = "The Apache Software License, Version 2.0",
            url = "http://www.apache.org/licenses/LICENSE-2.0.txt",
        ))

    return _pom_tmpl.format(
        group_id = ctx.attr.group_id,
        artifact_id = ctx.attr.artifact_id,
        version = ctx.attr.version,
        packaging = _packaging_type(ctx.file.src),
        dependencies = "\n".join(dependencies),
        licenses = "\n".join(licenses),
    )

def _create_metadata_string(ctx):
    """Returns the string contents of maven-metadata.xml for the group."""
    return _metadata_tmpl.format(
        group_id = ctx.attr.group_id,
        artifact_id = ctx.attr.artifact_id,
        version = ctx.attr.version,
        last_updated = ctx.attr.last_updated,
    )

def _rename_artifact(ctx, tpl_string, src_file, packaging_type):
    """Rename the artifact to match maven naming conventions."""
    artifact = ctx.actions.declare_file(tpl_string % (ctx.attr.artifact_id, ctx.attr.version, packaging_type))
    ctx.actions.run_shell(
        inputs = [src_file],
        outputs = [artifact],
        command = "cp %s %s" % (src_file.path, artifact.path),
    )
    return artifact

def _override_license_file(ctx, src_file):
    """Append a LICENSE file into the src if exists"""
    artifact_with_license = ctx.actions.declare_file("%s-with-LICENSE.%s" % (src_file.basename, src_file.extension))
    commands = []
    commands.append("cp %s %s" % (src_file.path, artifact_with_license.path))

    # Append a given LICENSE file to the root directory.
    commands.append("%s -uf %s -C %s %s" % (
        ctx.executable._jar.path,
        artifact_with_license.path,
        ctx.file.license_file.dirname,
        ctx.file.license_file.basename,
    ))

    # Remove the LICENSE files in META_INF.
    # (Ignore zip error: Nothing to do)
    commands.append("(zip -dq %s META-INF/LICENSE  META-INF/LICENSE.txt || true)" % (artifact_with_license.path))

    ctx.actions.run_shell(
        inputs = [src_file, ctx.file.license_file, ctx.executable._jar],
        outputs = [artifact_with_license],
        command = "&&".join(commands),
        tools = [ctx.executable._jar],
    )
    return artifact_with_license

def _maven_artifact_impl(ctx):
    """Generates maven repository for a single artifact."""
    pom = ctx.actions.declare_file(
        "%s-%s.pom" % (ctx.attr.artifact_id, ctx.attr.version),
    )
    ctx.actions.write(output = pom, content = _create_pom_string(ctx))

    metadata = ctx.actions.declare_file("%s-maven-metadata.xml" % (ctx.label.name))
    ctx.actions.write(output = metadata, content = _create_metadata_string(ctx))

    # Rename binary artifact to artifact_id-version.packaging_type
    src = _override_license_file(ctx, ctx.file.src) if ctx.file.license_file else ctx.file.src
    artifact = _rename_artifact(ctx, "%s-%s.%s", src, _packaging_type(src))

    arguments = [
        "--group_path=%s" % ctx.attr.group_id.replace(".", "/"),
        "--artifact_id=%s" % ctx.attr.artifact_id,
        "--version=%s" % ctx.attr.version,
        "--artifact=%s" % artifact.path,
        "--pom=%s" % pom.path,
        "--metadata=%s" % metadata.path,
        "--output=%s" % ctx.outputs.m2repository.path,
    ]

    inputs = [pom, metadata, artifact]

    if ctx.file.src_jar != None:
        # Rename sources jar artifact to artifact_id-version-sources.jar
        source = _rename_artifact(ctx, "%s-%s-sources.%s", ctx.file.src_jar, "jar")
        arguments.append("--source=%s" % source.path)
        inputs.append(source)

    if ctx.file.javadoc_jar != None:
        # Rename javadoc jar artifact to artifact_id-version-javadoc.jar
        javadoc = _rename_artifact(ctx, "%s-%s-javadoc.%s", ctx.file.javadoc_jar, "jar")
        arguments += ["--javadoc=%s" % javadoc.path]
        inputs += [javadoc]

    ctx.actions.run(
        inputs = inputs,
        outputs = [ctx.outputs.m2repository],
        arguments = arguments,
        executable = ctx.executable._maven_artifact,
        progress_message = (
            "Packaging repository: %s" % ctx.outputs.m2repository.short_path
        ),
    )

def _maven_repository_impl(ctx):
    """Generates maven repository for multiple artifacts."""
    source_files = []
    for src in ctx.attr.srcs:
        source_files.extend(src.files.to_list())
    ctx.actions.run(
        inputs = source_files,
        outputs = [ctx.outputs.m2repository],
        arguments = [
            "--sources=%s" % ",".join([f.path for f in source_files]),
            "--output=%s" % ctx.outputs.m2repository.path,
        ],
        executable = ctx.executable._maven_repository,
        progress_message = (
            "Packaging repository: %s" % ctx.outputs.m2repository.short_path
        ),
    )

maven_artifact = rule(
    implementation = _maven_artifact_impl,
    attrs = {
        "src": attr.label(
            mandatory = True,
            allow_single_file = [".aar", ".jar", ".apk"],
        ),
        "src_jar": attr.label(
            mandatory = False,
            allow_single_file = [".jar"],
        ),
        "javadoc_jar": attr.label(
            mandatory = False,
            allow_single_file = [".jar", ".zip"],
        ),
        "group_id": attr.string(mandatory = True),
        "artifact_id": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
        "last_updated": attr.string(mandatory = True),
        "license_file": attr.label(
            mandatory = False,
            allow_single_file = ["LICENSE"],
        ),
        "license_name": attr.string(mandatory = False),
        "license_url": attr.string(mandatory = False),
        "artifact_deps": attr.string_list(),
        "_jar": attr.label(
            default = Label("@bazel_tools//tools/jdk:jar"),
            executable = True,
            allow_files = True,
            cfg = "exec",
        ),
        "_maven_artifact": attr.label(
            default = Label("//build_extensions:maven_artifact"),
            executable = True,
            allow_files = True,
            cfg = "exec",
        ),
    },
    outputs = {
        "m2repository": "%{name}.zip",
    },
)

maven_repository = rule(
    implementation = _maven_repository_impl,
    attrs = {
        "srcs": attr.label_list(allow_rules = ["maven_artifact"]),
        "_maven_repository": attr.label(
            default = Label("//build_extensions:maven_repository"),
            executable = True,
            allow_files = True,
            cfg = "exec",
        ),
    },
    outputs = {
        "m2repository": "%{name}.zip",
    },
)
