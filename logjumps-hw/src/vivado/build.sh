#!/usr/bin/env bash
# --------------------------------------------------------------
# build.sh, Generic Vivado OOC synth + impl flow
#
# Usage:
#   ./build.sh <impl_file.f> [KEY=VALUE ...]
#
# The .f file lists source files (one per line, in compilation order).
# Lines starting with # and blank lines are ignored.
# The top module defaults to the .f filename stem after the "impl_" prefix,
# e.g. impl_modacc.f -> top module "modacc".
#
# Examples:
#   ./build.sh impl_modacc.f FREQ=400
#   ./build.sh impl_modacc.f FREQ=400 LOGQ=256 NUM_INPUTS=16
#   ./build.sh impl_alu.f    FREQ=500 TOP=alu_wrapper PART=xcu280-fsvh2892-2L-e
#
# Reserved parameters:
#   FREQ  , target frequency in MHz       (default: 455)
#   TOP   , top-level module name          (default: derived from .f filename)
#   PART  , FPGA part string               (default: xcu55c-fsvh2892-2L-e)
#   ELAB  , RTL elaboration pass (0/1)     (default: 1)
#            reads back all parameters/localparams from the hierarchy
#   ELAB_DEPTH, hierarchy depth to print   (default: -1 = all)
#            0 = top module only, 1 = +direct children, etc.
#   EFFORT, implementation effort level     (default: 0)
#            0 = normal (single-pass place -> phys_opt -> route)
#            1 = high   (Perf_ExploreWithRemap, post-route phys_opt)
#            2 = aggressive (SSI SpreadLogic, 4x phys_opt, route -directive
#                 AggressiveExplore, post-route phys_opt with retime)
#            3 = ultra  (everything in 2 + incremental re-place/route if
#                 timing is still not met)
#
# All other KEY=VALUE pairs are forwarded to synth_design -generic,
# allowing you to set Verilog parameters on the top module.
# --------------------------------------------------------------

set -eo pipefail

# -- Colors & helpers ------------------------------------------
RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[0;33m'
CYN=$'\033[0;36m'; BLD=$'\033[1m'; RST=$'\033[0m'

info()  { printf "${CYN}[INFO]${RST}  %s\n" "$*"; }
warn()  { printf "${YEL}[WARN]${RST}  %s\n" "$*"; }
err()   { printf "${RED}[ERR]${RST}   %s\n" "$*" >&2; }
fatal() { err "$@"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -- Usage / help ----------------------------------------------
usage() {
    sed -n '2,/^$/{ s/^# \?//; p }' "$0"
    exit 1
}
[[ $# -lt 1 || "$1" == "-h" || "$1" == "--help" ]] && usage

# -- Validate .f file -----------------------------------------
F_FILE="$1"; shift

# Resolve relative paths against cwd, not script dir
if [[ "${F_FILE}" != /* ]]; then
    F_FILE="$(pwd)/${F_FILE}"
fi

[[ -f "${F_FILE}" ]] || fatal "File list not found: ${F_FILE}"
[[ "${F_FILE}" == *.f ]] || warn "File '${F_FILE}' does not end in .f, proceeding anyway."

# Count non-blank, non-comment source lines
SRC_COUNT=$(grep -cvE '^\s*(#|$)' "${F_FILE}" || true)
[[ ${SRC_COUNT} -gt 0 ]] || fatal "No source files listed in ${F_FILE}"
info "Found ${SRC_COUNT} source file(s) in $(basename "${F_FILE}")"

# -- Source Vivado environment ---------------------------------
VIVADO_SETTINGS="${VIVADO_SETTINGS:-/tools/Xilinx/Vivado/2024.2/settings64.sh}"
if [[ ! -f "${VIVADO_SETTINGS}" ]]; then
    fatal "Vivado settings not found at ${VIVADO_SETTINGS}\n       Set VIVADO_SETTINGS to point to your settings64.sh"
fi
set +u
source "${VIVADO_SETTINGS}"
set -u
info "Using Vivado: $(which vivado)"

# -- Build a unique run tag from arguments ---------------------
# Keeps journal/log files separate for parallel builds.
F_STEM="$(basename "${F_FILE}" .f)"
if [[ $# -gt 0 ]]; then
    ARGS_TAG=$(printf '%s_' "$@" | sed 's/[= ]/_/g; s/_$//')
    RUN_TAG="${F_STEM}__${ARGS_TAG}"
else
    RUN_TAG="${F_STEM}__default"
fi

RUN_DIR="${SCRIPT_DIR}/build/${RUN_TAG}"
mkdir -p "${RUN_DIR}"
cd "${RUN_DIR}"

info "Run directory: ${RUN_DIR}"

# -- Launch Vivado ---------------------------------------------
info "Launching Vivado in batch mode..."
echo ""

vivado -mode batch -source "${SCRIPT_DIR}/build.tcl" \
    -journal "${RUN_DIR}/vivado.jou" \
    -log "${RUN_DIR}/vivado.log" \
    -tclargs "F_FILE=${F_FILE}" "$@"

EXIT_CODE=$?

echo ""
if [[ ${EXIT_CODE} -eq 0 ]]; then
    info "${GRN}Build finished successfully.${RST}  Reports in: ${RUN_DIR}/"
else
    err "Vivado exited with code ${EXIT_CODE}.  Check: ${RUN_DIR}/vivado.log"
fi

exit ${EXIT_CODE}