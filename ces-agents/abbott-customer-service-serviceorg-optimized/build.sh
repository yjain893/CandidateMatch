#!/bin/bash
# Builds the optimized agent package and its zip. Run from this folder.
set -e
SKILL=~/.claude/skills/ces-agent-builder/scripts
rm -rf out
python3 $SKILL/build_agent.py spec.json --no-zip --selftest | tail -3
python3 optimize_descriptions.py out/Abbott_Customer_Service_ServiceOrg_Optimized
python3 finalize_package.py out/Abbott_Customer_Service_ServiceOrg_Optimized
python3 $SKILL/validate_package.py out/Abbott_Customer_Service_ServiceOrg_Optimized | tail -2
(cd out && rm -f Abbott_Customer_Service_ServiceOrg_Optimized.zip && zip -qr Abbott_Customer_Service_ServiceOrg_Optimized.zip Abbott_Customer_Service_ServiceOrg_Optimized -x "*/.DS_Store")
python3 $SKILL/validate_package.py out/Abbott_Customer_Service_ServiceOrg_Optimized.zip | tail -2
ls -la out/*.zip
