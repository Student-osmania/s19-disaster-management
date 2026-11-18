#!/usr/bin/env python3
"""Generate the Python gRPC stubs from proto/incident_store.proto (cross-platform: Windows, Linux, macOS).

Output: services/common/s19common/pb/{incident_store_pb2.py, incident_store_pb2_grpc.py, __init__.py}
Usage : python scripts/gen_proto.py [repo_root]     (the Dockerfile calls it with /src)
Needs : pip install grpcio-tools   (already in services/requirements.txt)
"""
import pathlib
import re
import sys

from grpc_tools import protoc
import grpc_tools


def main() -> int:
    root = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1]
    proto_dir = root / "proto"
    out = root / "services" / "common" / "s19common" / "pb"
    out.mkdir(parents=True, exist_ok=True)
    well_known = pathlib.Path(grpc_tools.__file__).parent / "_proto"
    rc = protoc.main([
        "grpc_tools.protoc",
        f"-I{proto_dir}",
        f"-I{well_known}",
        f"--python_out={out}",
        f"--grpc_python_out={out}",
        str(proto_dir / "incident_store.proto"),
    ])
    if rc != 0:
        print("protoc failed", file=sys.stderr)
        return rc
    grpc_file = out / "incident_store_pb2_grpc.py"
    # protoc emits "import incident_store_pb2 as ..." - make it a package import
    text = re.sub(r"^import incident_store_pb2 as", "from s19common.pb import incident_store_pb2 as",
                  grpc_file.read_text(encoding="utf-8"), flags=re.M)
    grpc_file.write_text(text, encoding="utf-8", newline="\n")
    (out / "__init__.py").touch()
    print(f"generated stubs in {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
