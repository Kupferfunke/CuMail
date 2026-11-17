#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$PROJECT_ROOT/Scripts/build-local.sh"
open "$PROJECT_ROOT/build/CuMail.app"
