#!/bin/bash
# Builds the baseline package, applies the console settings, validates and zips it. Run from this folder.
set -e
SKILL=~/.claude/skills/ces-agent-builder/scripts
rm -rf out
python3 $SKILL/build_agent.py spec.json --no-zip --selftest | tail -2
python3 finalize_package.py out/Abbott_Customer_Service_ServiceOrg
python3 $SKILL/validate_package.py out/Abbott_Customer_Service_ServiceOrg | tail -1
(cd out && zip -qr Abbott_Customer_Service_ServiceOrg.zip Abbott_Customer_Service_ServiceOrg -x "*/.DS_Store")
python3 $SKILL/validate_package.py out/Abbott_Customer_Service_ServiceOrg.zip | tail -1
python3 $SKILL/export_console_files.py spec.json out/Abbott_Customer_Service_ServiceOrg console | tail -1
