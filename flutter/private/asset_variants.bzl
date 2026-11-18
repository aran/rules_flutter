"""Which directories hold the resolution variants of an asset.

Shared by the pub package repository rule, which has to find the variant files
beside a listed asset, and the asset bundle, which groups the files it bundles
into assets and their variants. Both must agree, and both must agree with
flutter_tools, which finds a variant by the name of the directory it is in.
"""

visibility("//flutter/...")

def variant_scale(directory):
    """The scale a directory name stands for, or None for any other name.

    flutter_tools (`asset.dart`) takes a directory for a resolution variant's
    when its name matches `/?(\\d+(\\.\\d*)?)x$` and reads the scale from the
    match. The pattern is not anchored at the start, so `icons2x` is a `2x`
    directory too; that is kept, because a directory that is one for
    `flutter build` has to be one here for the same app to bundle the same
    files.

    Args:
        directory: The name of one directory (no `/`).

    Returns:
        The scale as a float (`"1.5x"` is 1.5, `"2x"` is 2.0), or None.
    """
    if not directory.endswith("x"):
        return None
    name = directory[:-1]

    # The trailing run of digits, then, before a `.` that precedes it, the run
    # of digits ahead of that: `\d+(\.\d*)?` read from the end.
    end = len(name)
    start = end
    for i in range(end - 1, -1, -1):
        if not name[i].isdigit():
            break
        start = i
    fraction = name[start:end]
    whole = ""
    if start > 0 and name[start - 1] == ".":
        dot = start - 1
        whole_start = dot
        for i in range(dot - 1, -1, -1):
            if not name[i].isdigit():
                break
            whole_start = i
        whole = name[whole_start:dot]
    if whole:
        return float(whole + "." + (fraction or "0"))
    if fraction:
        return float(fraction)
    return None
