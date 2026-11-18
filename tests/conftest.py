"""pytest bootstrap: generate the gRPC stubs automatically if they are missing (Windows-friendly:
`python -m pytest tests` works without running any shell script first)."""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
PB = ROOT / "services" / "common" / "s19common" / "pb" / "incident_store_pb2_grpc.py"

if not PB.exists():
    subprocess.check_call([sys.executable, str(ROOT / "scripts" / "gen_proto.py"), str(ROOT)])
