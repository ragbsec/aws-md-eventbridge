#!/usr/bin/env python3
"""
Event contract test — validates event payloads against the registered schema.

This is the enterprise guard: a producer's event must satisfy the OrderPlaced
contract (schemas/order-placed.v1.json), and a schema CHANGE must stay
backward-compatible. Run locally and in CI; a failure fails the pipeline so a
breaking change cannot ship and break downstream consumers.

Usage:
  contract_test.py validate <schema.json> <event.json> [<event.json> ...]
  contract_test.py compat   <old_schema.json> <new_schema.json>

Exit 0 = pass, non-zero = contract violation (CI-friendly).
No third-party deps required for the structural checks; if `jsonschema` is
installed it is used for full Draft-7 validation, otherwise a built-in subset
validator enforces required/type/additionalProperties.
"""
import json
import sys


def _load(path):
    with open(path) as f:
        return json.load(f)


def _schema_node(doc):
    # Accept either a bare JSON Schema or an OpenAPI doc with components.schemas.OrderPlaced
    if "components" in doc:
        return doc["components"]["schemas"]["OrderPlaced"]
    return doc


def _validate_builtin(schema, event):
    errors = []
    req = schema.get("required", [])
    for k in req:
        if k not in event:
            errors.append(f"missing required property: {k}")
    props = schema.get("properties", {})
    if schema.get("additionalProperties") is False:
        for k in event:
            if k not in props:
                errors.append(f"unexpected property (additionalProperties=false): {k}")
    type_map = {"string": str, "integer": int, "number": (int, float), "object": dict, "array": list, "boolean": bool}
    for k, spec in props.items():
        if k in event and "type" in spec:
            py = type_map.get(spec["type"])
            if py and not isinstance(event[k], py):
                errors.append(f"property {k}: expected {spec['type']}, got {type(event[k]).__name__}")
            if spec.get("type") == "integer" and isinstance(event[k], bool):
                errors.append(f"property {k}: expected integer, got boolean")
            if "minimum" in spec and isinstance(event[k], (int, float)) and event[k] < spec["minimum"]:
                errors.append(f"property {k}: {event[k]} < minimum {spec['minimum']}")
            if "minLength" in spec and isinstance(event[k], str) and len(event[k]) < spec["minLength"]:
                errors.append(f"property {k}: shorter than minLength {spec['minLength']}")
    return errors


def _validate(schema, event):
    try:
        import jsonschema  # type: ignore
        jsonschema.validate(event, schema)
        return []
    except ImportError:
        return _validate_builtin(schema, event)
    except Exception as e:  # jsonschema.ValidationError
        return [str(e).splitlines()[0]]


def cmd_validate(args):
    schema = _schema_node(_load(args[0]))
    failures = 0
    for ev_path in args[1:]:
        event = _load(ev_path)
        # Unwrap EventBridge envelope if present (detail holds the payload).
        payload = event.get("detail", event) if isinstance(event, dict) else event
        errs = _validate(schema, payload)
        if errs:
            failures += 1
            print(f"FAIL {ev_path}")
            for e in errs:
                print(f"     - {e}")
        else:
            print(f"PASS {ev_path}")
    return 1 if failures else 0


def cmd_compat(args):
    """Backward-compat check: new schema must not add required fields or remove
    properties that old consumers rely on."""
    old = _schema_node(_load(args[0]))
    new = _schema_node(_load(args[1]))
    errs = []
    old_req = set(old.get("required", []))
    new_req = set(new.get("required", []))
    added_required = new_req - old_req
    if added_required:
        errs.append(f"breaking: new required fields added: {sorted(added_required)}")
    removed_props = set(old.get("properties", {})) - set(new.get("properties", {}))
    if removed_props:
        errs.append(f"breaking: properties removed: {sorted(removed_props)}")
    if errs:
        print("FAIL backward-compatibility")
        for e in errs:
            print(f"     - {e}")
        return 1
    print("PASS backward-compatibility")
    return 0


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "validate":
        return cmd_validate(args)
    if cmd == "compat":
        return cmd_compat(args)
    print(f"unknown command: {cmd}")
    return 2


if __name__ == "__main__":
    sys.exit(main())
