#!/usr/bin/env python3
"""Copy every non-system dylib the app needs into Contents/Frameworks and rewrite load paths."""
import os
import shutil
import subprocess
import sys

SYSTEM_PREFIXES = ("/usr/lib/", "/System/")


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def load_commands(path):
    deps, rpaths = [], []
    lines = run("otool", "-l", path).splitlines()
    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped in ("cmd LC_LOAD_DYLIB", "cmd LC_LOAD_WEAK_DYLIB", "cmd LC_REEXPORT_DYLIB"):
            name = lines[index + 2].strip().split(" (offset")[0].replace("name ", "", 1)
            deps.append(name)
        elif stripped == "cmd LC_RPATH":
            rpath = lines[index + 2].strip().split(" (offset")[0].replace("path ", "", 1)
            rpaths.append(rpath)
    return deps, rpaths


def resolve(dep, owner, rpaths):
    owner_dir = os.path.dirname(os.path.realpath(owner))
    if dep.startswith("@loader_path/"):
        return os.path.realpath(os.path.join(owner_dir, dep[len("@loader_path/"):]))
    if dep.startswith("@rpath/"):
        tail = dep[len("@rpath/"):]
        for rpath in rpaths:
            base = rpath.replace("@loader_path", owner_dir)
            candidate = os.path.join(base, tail)
            if os.path.exists(candidate):
                return os.path.realpath(candidate)
        for base in ("/opt/homebrew/lib",):
            candidate = os.path.join(base, tail)
            if os.path.exists(candidate):
                return os.path.realpath(candidate)
        return None
    if dep.startswith("@"):
        return None
    return os.path.realpath(dep)


def main():
    app = sys.argv[1]
    binary = os.path.join(app, "Contents/MacOS/Lumora")
    frameworks = os.path.join(app, "Contents/Frameworks")
    os.makedirs(frameworks, exist_ok=True)

    copied = {}
    queue = [binary]
    rewrites = {}

    while queue:
        current = queue.pop()
        deps, rpaths = load_commands(current)
        for dep in deps:
            if dep.startswith(SYSTEM_PREFIXES):
                continue
            source = resolve(dep, current, rpaths)
            if source is None or source.startswith(SYSTEM_PREFIXES):
                continue
            if not os.path.exists(source):
                sys.exit(f"missing dependency {dep} of {current}")
            name = os.path.basename(source)
            rewrites.setdefault(current, []).append((dep, f"@rpath/{name}"))
            if source not in copied:
                target = os.path.join(frameworks, name)
                shutil.copy2(source, target)
                os.chmod(target, 0o755)
                copied[source] = target
                queue.append(target)

    for path, changes in rewrites.items():
        args = ["install_name_tool"]
        for old, new in changes:
            args += ["-change", old, new]
        if path != binary:
            args += ["-id", f"@rpath/{os.path.basename(path)}"]
        args.append(path)
        subprocess.run(args, check=True, capture_output=True)

    for target in copied.values():
        subprocess.run(["install_name_tool", "-id", f"@rpath/{os.path.basename(target)}", target], check=True, capture_output=True)
        _, rpaths = load_commands(target)
        for rpath in rpaths:
            subprocess.run(["install_name_tool", "-delete_rpath", rpath, target], capture_output=True)
        subprocess.run(["install_name_tool", "-add_rpath", "@loader_path", target], capture_output=True)

    _, binary_rpaths = load_commands(binary)
    if "@executable_path/../Frameworks" not in binary_rpaths:
        subprocess.run(["install_name_tool", "-add_rpath", "@executable_path/../Frameworks", binary], check=True)

    print(f"bundled {len(copied)} libraries")


if __name__ == "__main__":
    main()
