import json
import os
import pprint
import re
import uuid

NAMESPACE = uuid.UUID("6f1c5f0e-2f6d-4f57-9f55-6f0c6a7a1b11")


def stable_uuid(*parts):
    """Same inputs give the same id, so rebuilding a package gives clean diffs."""
    return str(uuid.uuid5(NAMESPACE, "/".join(str(p) for p in parts)))


def folder_name(display_name):
    """'Root agent' -> 'Root_agent' (the console does the same for its exports)."""
    out = re.sub(r"[^A-Za-z0-9_\-]+", "_", display_name.strip())
    return out.strip("_") or "item"


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
        fh.write("\n")


def write_text(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text if text.endswith("\n") else text + "\n")


def py_literal(obj, indent=4):
    """Python source for a JSON-like value, continuation lines indented."""
    text = pprint.pformat(obj, width=100, sort_dicts=False)
    return text.replace("\n", "\n" + " " * indent)


def snake(name):
    return re.sub(r"[^a-z0-9_]+", "_", name.strip().lower()).strip("_")


class SpecError(Exception):
    pass


def need(d, key, where):
    if key not in d or d[key] in (None, ""):
        raise SpecError("%s: '%s' is required" % (where, key))
    return d[key]


_PLAIN = re.compile(r"[A-Za-z_][A-Za-z0-9_.\-]*$")


def _yaml_scalar(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    s = str(v)
    if _PLAIN.match(s) and s.lower() not in ("true", "false", "null", "yes", "no", "on", "off", "y", "n", "~"):
        return s
    return json.dumps(s, ensure_ascii=False)


def to_yaml(obj, indent=0):
    """Small YAML writer for dicts, lists and scalars (every non-trivial string is JSON-quoted, which is valid YAML)."""
    pad = "  " * indent
    if isinstance(obj, dict):
        if not obj:
            return pad + "{}"
        out = []
        for k, v in obj.items():
            if isinstance(v, (dict, list)) and v:
                out.append("%s%s:" % (pad, _yaml_scalar(k)))
                out.append(to_yaml(v, indent + 1))
            else:
                out.append("%s%s: %s" % (pad, _yaml_scalar(k), "{}" if isinstance(v, dict) else "[]" if isinstance(v, list) else _yaml_scalar(v)))
        return "\n".join(out)
    if isinstance(obj, list):
        if not obj:
            return pad + "[]"
        out = []
        for item in obj:
            if isinstance(item, (dict, list)) and item:
                inner = to_yaml(item, indent + 1).split("\n")
                out.append("%s- %s" % (pad, inner[0].lstrip()))
                out.extend(inner[1:])
            else:
                out.append("%s- %s" % (pad, "{}" if isinstance(item, dict) else "[]" if isinstance(item, list) else _yaml_scalar(item)))
        return "\n".join(out)
    return pad + _yaml_scalar(obj)
